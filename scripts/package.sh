#!/bin/bash
# Build "Kitty Finder.app" and zip it for sharing: dist/KittyFinder-<version>.zip
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
VERSION="$VERSION" "$ROOT/scripts/bundle.sh"
mkdir -p "$ROOT/dist"
ZIP="$ROOT/dist/KittyFinder-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$ROOT/build/Kitty Finder.app" "$ZIP"
echo "packaged $ZIP ($(du -h "$ZIP" | cut -f1))"
