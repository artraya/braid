#!/bin/bash
# Builds Resources/AppIcon.icns from scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Resources
TMP=$(mktemp -d)
swiftc -O scripts/make-icon.swift -o "$TMP/make-icon"
"$TMP/make-icon" "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
rm -rf "$TMP"
echo "wrote Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"
