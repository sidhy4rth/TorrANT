#!/bin/bash
# Builds build/TorrANT.app (ad-hoc signed, Apple Silicon).
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build -c release
BIN="$(swift build -c release --show-bin-path)/TorrANT"

APP=build/TorrANT.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$APP/Contents/MacOS/TorrANT"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Sources/TorrANT/Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"

# App icon, drawn by the app itself from the sketched ant.
ICON_SRC=build/icon-1024.png
"$APP/Contents/MacOS/TorrANT" --export-icon "$PWD/$ICON_SRC"
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"
