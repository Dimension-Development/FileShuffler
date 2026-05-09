#!/usr/bin/env bash
#
# Wrap the swift-build executable into a minimal .app bundle so it launches
# with normal macOS window/dock behaviour. Used until a full Xcode project
# is set up.
#
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="FileShuffler.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/FileShuffler "$APP/Contents/MacOS/FileShuffler"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>            <string>FileShuffler</string>
    <key>CFBundleIdentifier</key>            <string>uk.co.luke.FileShuffler</string>
    <key>CFBundleName</key>                  <string>File Shuffler</string>
    <key>CFBundleDisplayName</key>           <string>File Shuffler</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>0.1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
</dict>
</plist>
PLIST

echo "Built ./$APP"
echo "Run it with: open ./$APP"
