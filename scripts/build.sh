#!/bin/bash
# Build + sign with the stable identity so Keychain ACLs and TCC grants
# survive rebuilds (ADR-0004). Always use this instead of bare `swift build`.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build "$@"
BIN="$(swift build --show-bin-path "$@")/MsNotesApp"
codesign --force --sign "ms-notes Development" --identifier "no.msnotes.app" "$BIN"
echo "signed: $BIN"
