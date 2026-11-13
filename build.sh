#!/bin/bash
# Builds "ZT2 Launcher.app" next to this script.
set -euo pipefail
cd "$(dirname "$0")"
APP="ZT2 Launcher.app"
rm -rf "$APP" build; mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

swift Tools/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

swiftc -O -parse-as-library -target arm64-apple-macos14 Sources/*.swift -o "$APP/Contents/MacOS/ZT2Launcher"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleExecutable</key><string>ZT2Launcher</string>
<key>CFBundleIdentifier</key><string>com.macprotips.zt2launcher</string>
<key>CFBundleName</key><string>ZT2 Launcher</string>
<key>CFBundleDisplayName</key><string>ZT2 Launcher</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.9.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.simulation-games</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
# Ad-hoc by default; set SIGN_IDENTITY to a Developer ID to sign for distribution.
ID="${SIGN_IDENTITY:--}"
if [ "$ID" = "-" ]; then
  codesign -s - --force "$APP"
else
  codesign -s "$ID" --force --options runtime --timestamp "$APP"
fi
rm -rf build
echo "Built $APP"
