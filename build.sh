#!/bin/sh
# Builds UsageBar.app, launches it, and registers it to start at login.
set -e
cd "$(dirname "$0")"
APP=UsageBar.app
mkdir -p $APP/Contents/MacOS
swiftc -Osize -o $APP/Contents/MacOS/UsageBar UsageBar.swift && strip $APP/Contents/MacOS/UsageBar
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleName</key><string>UsageBar</string><key>CFBundleIdentifier</key><string>local.usagebar</string>
<key>CFBundleExecutable</key><string>UsageBar</string><key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/></dict></plist>
PLIST
pkill -x UsageBar || true
open $APP
cat > ~/Library/LaunchAgents/local.usagebar.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>Label</key><string>local.usagebar</string><key>RunAtLoad</key><true/>
<key>ProgramArguments</key><array><string>$PWD/$APP/Contents/MacOS/UsageBar</string></array></dict></plist>
PLIST
echo "Built, launched, and set to start at login."
