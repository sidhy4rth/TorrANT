#!/bin/bash
# Packs build/TorrANT.app into a zip to hand to a friend (engines are inside, no Homebrew needed).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d build/TorrANT.app ] || ./build.sh
V="$(git describe --tags --always 2>/dev/null || date +%Y%m%d)"
OUT="build/TorrANT-$V.zip"
rm -f "$OUT"
ditto -c -k --sequesterRsrc --keepParent build/TorrANT.app "$OUT"
echo "Packed $OUT ($(du -h "$OUT" | cut -f1))"
