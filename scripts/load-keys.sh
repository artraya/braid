#!/bin/bash
# Moves the keys from .env into the macOS Keychain, where the app reads them.
# Run once after editing .env, and again after installing a new build.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=/Applications/Braid.app/Contents/MacOS/Braid
if [ -x "$APP" ]; then
  # Import via the installed app so it owns the Keychain items and is never
  # prompted for consent when reading them back.
  "$APP" --import-keys .env
  "$APP" --check-keys
else
  echo "Braid is not installed in /Applications — run ./scripts/build-app.sh first" >&2
  exit 1
fi
