#!/bin/bash
# Copies the download engine (aria2c) and the Drive engine (rclone) into the app, so TorrANT
# runs on a Mac without Homebrew. aria2c's Homebrew libraries come along and are re-linked to
# load from inside the app (@loader_path); system libraries stay as they are.
set -euo pipefail
APP="$1"
RES="$APP/Contents/Resources"
ARIA="$(readlink -f "$(command -v aria2c)")"
RCLONE="$(readlink -f "$(command -v rclone)")"

mkdir -p "$RES/aria2/lib" "$RES/rclone"
cp -f "$ARIA" "$RES/aria2/aria2c"; chmod 755 "$RES/aria2/aria2c"
cp -f "$RCLONE" "$RES/rclone/rclone"; chmod 755 "$RES/rclone/rclone"

# Non-system libraries a binary links to (Homebrew paths, or @rpath ones resolved by Homebrew).
deps() { otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -E '^/opt/homebrew|^/usr/local|^@rpath' || true; }
resolve() {
  case "$1" in
    @rpath/*) local n="${1#@rpath/}"; find /opt/homebrew/opt /opt/homebrew/lib -name "$n" -print -quit 2>/dev/null ;;
    *) readlink -f "$1" ;;
  esac
}

queue=("$RES/aria2/aria2c")
while [ ${#queue[@]} -gt 0 ]; do
  f="${queue[0]}"; queue=("${queue[@]:1}")
  for d in $(deps "$f"); do
    name="$(basename "$d")"
    dst="$RES/aria2/lib/$name"
    if [ ! -f "$dst" ]; then
      src="$(resolve "$d")"
      [ -n "$src" ] || { echo "can't find $d needed by $f" >&2; exit 1; }
      cp -f "$src" "$dst"; chmod 644 "$dst"
      install_name_tool -id "@loader_path/$name" "$dst" 2>/dev/null
      queue+=("$dst")
    fi
    if [ "$f" = "$RES/aria2/aria2c" ]; then
      install_name_tool -change "$d" "@loader_path/lib/$name" "$f" 2>/dev/null
    else
      install_name_tool -change "$d" "@loader_path/$name" "$f" 2>/dev/null
    fi
  done
done

# OpenSSL loads its "legacy" provider plug-in at runtime from its own install folder. Bring it
# along and point it at the bundled libcrypto; Aria2.swift sets OPENSSL_MODULES to this folder.
MODS="$(dirname "$(readlink -f "$(brew --prefix openssl@4 2>/dev/null || echo /opt/homebrew/opt/openssl@4)/lib/libcrypto.4.dylib")")/ossl-modules"
if [ -f "$MODS/legacy.dylib" ]; then
  mkdir -p "$RES/aria2/lib/ossl-modules"
  cp -f "$MODS/legacy.dylib" "$RES/aria2/lib/ossl-modules/legacy.dylib"; chmod 644 "$RES/aria2/lib/ossl-modules/legacy.dylib"
  for d in $(deps "$RES/aria2/lib/ossl-modules/legacy.dylib"); do
    install_name_tool -change "$d" "@loader_path/../$(basename "$d")" "$RES/aria2/lib/ossl-modules/legacy.dylib" 2>/dev/null
  done
  codesign --force --sign - "$RES/aria2/lib/ossl-modules/legacy.dylib" >/dev/null 2>&1
fi

# Re-sign each piece after rewriting it (ad-hoc, like the app).
for f in "$RES"/aria2/lib/*.dylib "$RES/aria2/aria2c" "$RES/rclone/rclone"; do codesign --force --sign - "$f" >/dev/null 2>&1; done
echo "Bundled aria2 ($(ls "$RES/aria2/lib" | wc -l | xargs) libraries) and rclone"
