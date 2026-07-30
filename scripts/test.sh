#!/bin/bash
# Runs the test suite on Command Line Tools (no Xcode).
# CLT ships Swift Testing's macro plugin and frameworks in non-default
# locations; these flags point the build at them (see ADR-0004).
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools
exec swift test \
  -Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib" \
  "$@"
