#!/bin/sh
# Builds Lid.app (Apple silicon and Intel), signs it with your Developer ID,
# and packs it into .build/dist/Lid.dmg. With ASC_KEY_ID, ASC_ISSUER and
# ASC_P8 (an App Store Connect API key) set, it also notarizes the .dmg.
set -eu
cd "$(dirname "$0")"

VERSION=${VERSION:-0.1.0}
BUILD=$(git rev-list --count HEAD)
SIGN=${SIGN:-"Developer ID Application"}
OUT=.build/dist
APP=$OUT/Lid.app

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Lid

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/dmg"
cp "$BIN" "$APP/Contents/MacOS/Lid"
cp icon/Lid.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>stream.cross.lid</string>
  <key>CFBundleName</key><string>Lid</string>
  <key>CFBundleExecutable</key><string>Lid</string>
  <key>CFBundleIconFile</key><string>Lid</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Lid asks for your admin password once, to let it turn sleep on and off.</string>
</dict></plist>
EOF

codesign --force --options runtime --timestamp --sign "$SIGN" "$APP"
cp -R "$APP" "$OUT/dmg/"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname Lid -srcfolder "$OUT/dmg" -format UDZO -ov "$OUT/Lid.dmg"
codesign --timestamp --sign "$SIGN" "$OUT/Lid.dmg"

if [ -n "${ASC_KEY_ID:-}" ]; then
  xcrun notarytool submit "$OUT/Lid.dmg" --key "$ASC_P8" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" --wait
  xcrun stapler staple "$OUT/Lid.dmg"
fi
echo "$OUT/Lid.dmg"
