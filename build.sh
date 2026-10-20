#!/bin/bash
# Builds build/Session Sync.app (universal arm64 + x86_64, ad-hoc signed) and a .dmg.
# Usage: ./build.sh [version]
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-1.1.0}"
APP="build/Session Sync.app"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos12" Sources/*.swift -o "build/SessionSync-$arch"
done
lipo -create build/SessionSync-arm64 build/SessionSync-x86_64 -output "$APP/Contents/MacOS/SessionSync"
rm build/SessionSync-arm64 build/SessionSync-x86_64

cp AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Session Sync</string>
  <key>CFBundleDisplayName</key><string>Session Sync</string>
  <key>CFBundleIdentifier</key><string>com.ravijari.sessionsync</string>
  <key>CFBundleExecutable</key><string>SessionSync</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP"

mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -quiet -volname "Session Sync" -srcfolder build/dmg -ov -format UDZO "build/SessionSync-$VERSION.dmg"
rm -rf build/dmg
echo "built: $APP"
echo "built: build/SessionSync-$VERSION.dmg"
