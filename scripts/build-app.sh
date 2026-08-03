#!/bin/bash
# Assembles and signs dist/Braid.app. This is the deploy artifact for
# /Applications.
#
# Built with xcodebuild rather than `swift build`, which mlx-swift's own README
# is explicit about: SwiftPM on the command line cannot compile Metal shaders,
# so a `swift build` produces a binary that dies at the first MLX call with
# "Failed to load the default metallib". ADR-0004 records why Xcode is now a
# prerequisite. The unit tests still run under plain SwiftPM (scripts/test.sh),
# because the test target does not depend on BraidMLX.
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=.build/xcode
xcodebuild build -scheme braid -destination 'platform=OS X' \
  -configuration Release -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO >/dev/null
PRODUCTS="$DERIVED/Build/Products/Release"
BIN="$PRODUCTS/BraidApp"
[ -x "$BIN" ] || { echo "no binary at $BIN"; exit 1; }

APP=dist/Braid.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Braid"
# SwiftPM resource bundles have to travel with the binary. mlx-swift_Cmlx holds
# default.metallib — every Metal kernel MLX runs — and its absence is not a
# build error, only a crash on the first summary.
for bundle in "$PRODUCTS"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
[ -f Resources/AppIcon.icns ] || ./scripts/make-icon.sh
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>no.braid.app</string>
    <key>CFBundleName</key><string>Braid</string>
    <key>CFBundleDisplayName</key><string>Braid</string>
    <key>CFBundleExecutable</key><string>Braid</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Braid records your microphone during meetings you choose to record.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Braid records system audio (the other meeting participants) during meetings you choose to record.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign "ms-notes Development" --identifier "no.braid.app" "$APP"
codesign --verify --verbose=2 "$APP"
echo "built: $APP"
