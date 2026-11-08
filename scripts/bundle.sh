#!/bin/bash
# Build "build/Kitty Finder.app": universal app binary + patched rclone + icon, ad-hoc signed.
# Put your Google OAuth client in Config/GoogleOAuth.plist to build it in
# (see Config/GoogleOAuth.example.plist); otherwise people enter one in Settings.
# NO_GOOGLE_CLIENT=1 leaves it out even if present, for public releases.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
APP="$ROOT/build/Kitty Finder.app"

[ -x build/rclone ] || scripts/build-rclone.sh

for arch in arm64 x86_64; do
  swift build -c release --arch "$arch" 2>&1 | grep -E 'error|warning: |Compiling|Build complete' || true
  [ -x ".build/$arch-apple-macosx/release/KittyFinder" ] || { echo "build failed for $arch" >&2; exit 1; }
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/KittyFinder" \
  .build/arm64-apple-macosx/release/KittyFinder .build/x86_64-apple-macosx/release/KittyFinder
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp build/rclone "$APP/Contents/Resources/rclone"
cp build/rclone-COPYING "$APP/Contents/Resources/rclone-COPYING"
if [ "${NO_GOOGLE_CLIENT:-}" = "1" ]; then
  echo "note: NO_GOOGLE_CLIENT=1, so no Google client is built in; users enter one in Settings"
elif [ -f Config/GoogleOAuth.plist ]; then
  cp Config/GoogleOAuth.plist "$APP/Contents/Resources/GoogleOAuth.plist"
  echo "bundled Google OAuth client from Config/GoogleOAuth.plist"
else
  echo "note: no Config/GoogleOAuth.plist; users must enter a Google client in Settings"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>KittyFinder</string>
  <key>CFBundleIdentifier</key><string>app.kittyfinder.KittyFinder</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Kitty Finder</string>
  <key>CFBundleDisplayName</key><string>Kitty Finder</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Kitty Finder. Includes rclone (MIT).</string>
</dict>
</plist>
PLIST

# Ad-hoc signatures (no Apple Developer account): sign the helper first, then the app.
codesign --force --sign - "$APP/Contents/Resources/rclone"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "built $APP ($VERSION, build $BUILD_NUMBER)"
lipo -info "$APP/Contents/MacOS/KittyFinder"
