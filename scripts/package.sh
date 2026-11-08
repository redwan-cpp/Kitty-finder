#!/bin/bash
# Build "Kitty Finder.app" and zip it for sharing: dist/KittyFinder-<version>.zip
# With NO_GOOGLE_CLIENT=1 (public releases) the zip has no Google client built in
# and is named dist/KittyFinder-<version>-public.zip.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
VERSION="$VERSION" "$ROOT/scripts/bundle.sh"
mkdir -p "$ROOT/dist"
SUFFIX=""
[ "${NO_GOOGLE_CLIENT:-}" = "1" ] && SUFFIX="-public"
ZIP="$ROOT/dist/KittyFinder-$VERSION$SUFFIX.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$ROOT/build/Kitty Finder.app" "$ZIP"
echo "packaged $ZIP ($(du -h "$ZIP" | cut -f1))"
