#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=LidAwake.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS
for A in arm64 x86_64; do
  swiftc -O -wmo -target $A-apple-macos11 main.swift Mug.swift Safety.swift -o /tmp/lidawake-$A
done
lipo -create /tmp/lidawake-arm64 /tmp/lidawake-x86_64 -output $APP/Contents/MacOS/LidAwake
rm -f /tmp/lidawake-arm64 /tmp/lidawake-x86_64
strip -x $APP/Contents/MacOS/LidAwake
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LidAwake</string>
<key>CFBundleIdentifier</key><string>local.lidawake</string>
<key>CFBundleName</key><string>LidAwake</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
<key>CFBundleVersion</key><string>1.1.0</string>
<key>LSMinimumSystemVersion</key><string>11.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign -s - --force $APP
echo "built $APP ($(du -sh $APP | cut -f1))"
