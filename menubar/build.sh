#!/bin/bash
# Builds AppleMusicRemote.app from Main.swift — no Xcode required, just
# the Command Line Tools (swiftc). Run: ./build.sh
set -euo pipefail

cd "$(dirname "$0")"

APP="AppleMusicRemote.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/AppleMusicRemote" Main.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>AppleMusicRemote</string>
    <key>CFBundleDisplayName</key>
    <string>Apple Music Remote</string>
    <key>CFBundleIdentifier</key>
    <string>local.apple-music-remote</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>AppleMusicRemote</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "Built $APP — open it with: open $APP"
