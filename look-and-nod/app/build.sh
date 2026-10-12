#!/bin/bash
# Builds "Look and Nod.app" without opening Xcode, then packs the download zip.
# Runs on a Mac (GitHub builds it automatically, see .github/workflows/release.yml).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build
APP="$OUT/Look and Nod.app"
rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling for Apple silicon and Intel..."
for arch in arm64 x86_64; do
  xcrun -sdk macosx swiftc -O -parse-as-library \
    -target "$arch-apple-macos14.0" \
    app/LookAndNodApp.swift app/ContentView.swift \
    -o "$OUT/LookAndNod-$arch"
done
lipo -create "$OUT/LookAndNod-arm64" "$OUT/LookAndNod-x86_64" -output "$APP/Contents/MacOS/LookAndNod"

cp app/Info.plist "$APP/Contents/Info.plist"
iconutil -c icns app/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" || echo "Icon skipped"

# Free (ad hoc) signature so it runs on Apple silicon. People click Open Anyway the first time.
codesign --force --deep --sign - "$APP"

echo "Packing the download..."
PKG="$OUT/Look and Nod"
mkdir -p "$PKG"
cp -R "$APP" "$PKG/"
cp setup-kit/bulb_server.py "setup-kit/Setup Look and Nod.command" "setup-kit/Uninstall Look and Nod.command" "$PKG/"
cp "setup-kit/Read me first.md" "$PKG/"
chmod +x "$PKG/"*.command
(cd "$OUT" && ditto -c -k --keepParent "Look and Nod" "Look-and-Nod.zip")
echo "Done: $OUT/Look-and-Nod.zip"
