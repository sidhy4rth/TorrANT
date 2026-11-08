#!/bin/bash
# Builds build/TorrANT.app (ad-hoc signed, Apple Silicon).
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build -c release
BIN="$(swift build -c release --show-bin-path)/TorrANT"

# App icon, drawn by the app itself from the sketched ant. Run the bare
# binary, not the one inside the bundle: launching a half-built bundle makes
# macOS cache it with no icon, and the Dock then shows a blank tile.
mkdir -p build
ICON_SRC=build/icon-1024.png
"$BIN" --export-icon "$PWD/$ICON_SRC"

APP=build/TorrANT.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$APP/Contents/MacOS/TorrANT"
cp "$(dirname "$BIN")/TorrANTCatch" "$APP/Contents/MacOS/torrant-catch"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Sources/TorrANT/Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"

# Brave extension (copied to Application Support on launch, loaded unpacked from there).
EXT="$APP/Contents/Resources/BraveExtension"
cp -R Extension "$EXT"
mkdir -p "$EXT/fonts"
cp Sources/TorrANT/Resources/Fonts/BricolageGrotesque.ttf Sources/TorrANT/Resources/Fonts/Figtree.ttf "$EXT/fonts/"

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Download and Drive engines inside the app, so it runs on Macs without Homebrew.
scripts/bundle-engines.sh "$APP"

codesign --force --deep --sign - "$APP" >/dev/null

# Tell macOS about the finished bundle so Finder and the Dock pick up the icon.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
echo "Built $APP"
