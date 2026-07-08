#!/usr/bin/env bash
#
# Wrap the swift-build executable into a minimal .app bundle so it launches
# with normal macOS window/dock behaviour. Used until a full Xcode project
# is set up.
#
# Also (re)builds the AppIcon.icns from assets/icon-source.png so the bundle
# always picks up the latest source artwork. Both `sips` and `iconutil` ship
# with the Command Line Tools, so this works without full Xcode.
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Version stamped into Info.plist. Pass it for release builds
# (./scripts/bundle-app.sh 0.3.0); bare invocations get a dev marker so a
# forgotten argument can't ship an old-looking version number again.
VERSION="${1:-0.0.0-dev}"

swift build -c release

APP="FileShuffler.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/FileShuffler "$APP/Contents/MacOS/FileShuffler"

# ---- App icon ---------------------------------------------------------------
ICON_SOURCE="assets/icon-source.png"
if [[ -f "$ICON_SOURCE" ]]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    # macOS expects 10 sizes (5 logical, each at 1x and 2x).
    sips -z   16   16 "$ICON_SOURCE" --out "$ICONSET/icon_16x16.png"      >/dev/null
    sips -z   32   32 "$ICON_SOURCE" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
    sips -z   32   32 "$ICON_SOURCE" --out "$ICONSET/icon_32x32.png"      >/dev/null
    sips -z   64   64 "$ICON_SOURCE" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
    sips -z  128  128 "$ICON_SOURCE" --out "$ICONSET/icon_128x128.png"    >/dev/null
    sips -z  256  256 "$ICON_SOURCE" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
    sips -z  256  256 "$ICON_SOURCE" --out "$ICONSET/icon_256x256.png"    >/dev/null
    sips -z  512  512 "$ICON_SOURCE" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
    sips -z  512  512 "$ICON_SOURCE" --out "$ICONSET/icon_512x512.png"    >/dev/null
    sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    ICON_PLIST_LINE='<key>CFBundleIconFile</key>            <string>AppIcon</string>'
else
    echo "warning: $ICON_SOURCE not found — building without an app icon" >&2
    ICON_PLIST_LINE=""
fi

# ---- Info.plist -------------------------------------------------------------
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>            <string>FileShuffler</string>
    <key>CFBundleIdentifier</key>            <string>uk.co.luke.FileShuffler</string>
    <key>CFBundleName</key>                  <string>File Shuffler</string>
    <key>CFBundleDisplayName</key>           <string>File Shuffler</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>${VERSION}</string>
    <key>CFBundleVersion</key>               <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    ${ICON_PLIST_LINE}
</dict>
</plist>
PLIST

# ---- Ad-hoc sign so macOS doesn't re-quarantine on every move ---------------
# This is NOT Developer ID signing (which would need an Apple Developer
# account) — `-s -` uses an ad-hoc identity, which is enough to keep the
# .app stable across copies on this machine.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

# ---- Refresh the Finder/Launch Services icon cache for this bundle ----------
# Without this, Finder will keep showing the previous (or generic) icon for
# the .app even though the .icns inside has changed. `touch`-ing the bundle
# nudges the launch services daemon.
touch "$APP"

echo "Built ./$APP"
echo "Run it with: open ./$APP"
