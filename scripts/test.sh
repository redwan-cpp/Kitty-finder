#!/bin/bash
# Run the unit tests. With only Command Line Tools installed (no Xcode),
# SwiftPM needs to be pointed at the Swift Testing framework explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p)/Library/Developer"
FW="$DEV/Frameworks"
if [ -d "$FW/Testing.framework" ]; then
  exec swift test -Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$DEV/usr/lib" "$@"
fi
exec swift test "$@"
