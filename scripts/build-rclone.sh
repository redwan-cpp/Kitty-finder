#!/bin/bash
# Build the patched rclone that Kitty Finder bundles.
#   - clones the pinned rclone release into build/rclone-src
#   - applies patches/rclone/*.patch
#   - builds arm64 + amd64 and merges them into one universal binary
# Output: build/rclone (universal) and build/rclone-COPYING
set -euo pipefail

RCLONE_VERSION="v1.75.2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/rclone-src"
OUT="$ROOT/build"

command -v go >/dev/null || { echo "Go is required: brew install go" >&2; exit 1; }
mkdir -p "$OUT"

if [ ! -d "$SRC/.git" ]; then
  git clone --quiet --depth 1 --branch "$RCLONE_VERSION" https://github.com/rclone/rclone.git "$SRC"
fi
cd "$SRC"
git -c advice.detachedHead=false checkout --quiet "$RCLONE_VERSION"
git reset --quiet --hard "$RCLONE_VERSION"
git clean --quiet -fd
for p in "$ROOT"/patches/rclone/*.patch; do
  echo "applying $(basename "$p")"
  git apply "$p"
done

LDFLAGS="-s -w -X github.com/rclone/rclone/fs.Version=${RCLONE_VERSION}-kittyfinder"
for arch in arm64 amd64; do
  echo "building darwin/$arch"
  CGO_ENABLED=0 GOOS=darwin GOARCH=$arch go build -trimpath -ldflags "$LDFLAGS" -o "$OUT/rclone-$arch" .
done
lipo -create -output "$OUT/rclone" "$OUT/rclone-arm64" "$OUT/rclone-amd64"
rm -f "$OUT/rclone-arm64" "$OUT/rclone-amd64"
cp COPYING "$OUT/rclone-COPYING"
lipo -info "$OUT/rclone"
"$OUT/rclone" version | head -1
