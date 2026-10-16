#!/bin/zsh
# Builds ChatJump.app and installs it to /Applications.
set -e
cd "$(dirname "$0")"
APP=build/ChatJump.app
rm -rf build && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O -target arm64-apple-macos14 Sources/*.swift -o $APP/Contents/MacOS/ChatJump
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.chatjump</string>
  <key>CFBundleName</key><string>ChatJump</string>
  <key>CFBundleExecutable</key><string>ChatJump</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>ChatJump reads your Claude and ChatGPT tabs in Chrome so you can jump to them.</string>
</dict></plist>
PLIST
# A designated requirement tied to the bundle id (not the build hash) keeps the
# Accessibility grant valid across rebuilds.
codesign --force --sign - --requirements "=designated => identifier \"local.chatjump\"" $APP
mkdir -p /Applications
pkill -x ChatJump || true
rm -rf /Applications/ChatJump.app && cp -R $APP /Applications/
echo "Installed /Applications/ChatJump.app"
