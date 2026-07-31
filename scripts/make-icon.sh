#!/bin/bash
# Builds Resources/AppIcon.icns from Resources/AppIcon.png.
#
# The source art already carries the rounded-square shape and its own margin, so
# every size is a straight scale of it: macOS applies no mask of its own.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=Resources/AppIcon.png
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

TMP=$(mktemp -d)
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"

# The sizes iconutil expects, each at 1x and 2x.
for size in 16 32 128 256 512; do
  sips -Z "$size" "$SRC" --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -Z "$((size * 2))" "$SRC" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$TMP"
echo "wrote Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"
