#!/bin/bash
# Assembles and signs dist/Braid.app from a release build (ADR-0004:
# SwiftPM + CLT, no Xcode). This is the deploy artifact for /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/BraidApp"

APP=dist/Braid.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Braid"
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
    <key>LSMinimumSystemVersion</key><string>27.0</string>
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
