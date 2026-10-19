#!/bin/bash
# Builds a release binary and assembles dist/Retrolux.app with the Sparkle updater embedded.
# Signing: ad-hoc only (no Developer ID). Version comes from VERSION; updates are verified by Sparkle's EdDSA signature.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
FEED_URL="https://konzertblock.github.io/retrolux/appcast.xml"
PUBLIC_ED_KEY="pHM9GuwUniMtKmdRKk7+V6XdH31AFFTmwAnqE1ax+G0="
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP=dist/Retrolux.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Retrolux" "$APP/Contents/MacOS/Retrolux"
cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp resources/Retrolux.sdef "$APP/Contents/Resources/Retrolux.sdef"
SPARKLE="$(find .build/artifacts -type d -name Sparkle.framework -path '*macos-arm64_x86_64*' | head -1)"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Retrolux" 2>/dev/null || true
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Retrolux</string>
<key>CFBundleDisplayName</key><string>Retrolux</string>
<key>CFBundleIdentifier</key><string>io.github.konzertblock.retrolux</string>
<key>CFBundleExecutable</key><string>Retrolux</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>${VERSION}</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPhotoLibraryUsageDescription</key><string>Retrolux imports photos from your Photos library into its own library. Originals in Photos are not modified.</string>
<key>NSRemovableVolumesUsageDescription</key><string>Retrolux reads photos and legacy libraries from external volumes.</string>
<key>NSAppleScriptEnabled</key><true/>
<key>OSAScriptingDefinition</key><string>Retrolux.sdef</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Independent fan project, GPL-3.0-or-later. Not affiliated with Apple Inc.</string>
<key>SUFeedURL</key><string>${FEED_URL}</string>
<key>SUPublicEDKey</key><string>${PUBLIC_ED_KEY}</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
 <key>CFBundleTypeName</key><string>Image</string><key>CFBundleTypeRole</key><string>Viewer</string>
 <key>LSItemContentTypes</key><array><string>public.image</string></array></dict></array>
</dict></plist>
PLIST
# ad-hoc signing, innermost first (Sparkle's helpers, then the framework, then the app)
FW="$APP/Contents/Frameworks/Sparkle.framework"
for x in "$FW"/Versions/B/XPCServices/*.xpc "$FW"/Versions/B/Autoupdate "$FW"/Versions/B/Updater.app; do [ -e "$x" ] && codesign --force --sign - "$x"; done
codesign --force --sign - "$FW"
codesign --force --sign - "$APP"
echo "built $APP ($VERSION)"
