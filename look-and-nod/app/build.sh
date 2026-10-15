#!/bin/bash
# Builds "Look and Nod.app" without Xcode. Needs only the Command Line Tools:
#   xcode-select --install
# Put this file in a folder with ContentView.swift, MagicMouse.swift and LookAndNodApp.swift, then run:
#   bash build.sh
set -e
cd "$(dirname "$0")"
APP="Look and Nod.app"
BIN="$APP/Contents/MacOS/LookAndNod"

for f in ContentView.swift MagicMouse.swift LookAndNodApp.swift; do
  [ -f "$f" ] || { echo "Missing $f. Put it in this folder first."; exit 1; }
done
if grep -q "@main" ContentView.swift; then
  echo "ContentView.swift already has @main, so LookAndNodApp.swift isn't needed. Delete one of them."; exit 1
fi

echo "Building..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library \
  ContentView.swift MagicMouse.swift LookAndNodApp.swift \
  -framework SwiftUI -framework AppKit -framework CoreMotion \
  -o "$BIN"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Look and Nod</string>
  <key>CFBundleDisplayName</key><string>Look and Nod</string>
  <key>CFBundleIdentifier</key><string>com.ebenamanuel.lookandnod</string>
  <key>CFBundleExecutable</key><string>LookAndNod</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMotionUsageDescription</key><string>Look and Nod uses your AirPods' head tracking to tell which light you're facing and when you nod.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Done. Open it with:  open \"$APP\""
