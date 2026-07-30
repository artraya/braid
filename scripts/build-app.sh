#!/bin/bash
# Assembles and signs dist/ms-notes.app from a release build (ADR-0004:
# SwiftPM + CLT, no Xcode). This is the deploy artifact for /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MsNotesApp"

APP=dist/ms-notes.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/ms-notes"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>no.msnotes.app</string>
    <key>CFBundleName</key><string>ms-notes</string>
    <key>CFBundleDisplayName</key><string>ms-notes</string>
    <key>CFBundleExecutable</key><string>ms-notes</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>ms-notes records your microphone during meetings you choose to record.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>ms-notes records system audio (the other meeting participants) during meetings you choose to record.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign "ms-notes Development" --identifier "no.msnotes.app" "$APP"
codesign --verify --verbose=2 "$APP"
echo "built: $APP"
