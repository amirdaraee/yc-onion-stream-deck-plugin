#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PLUGIN="$ROOT/streamdeck/com.amirdaraee.yc-onion.sdPlugin"
APP="$PLUGIN/controllers/mac/YC Onion Controller.app"
ARCHIVE="$PLUGIN/controllers/mac/YC Onion Controller.zip"
MACOS="$APP/Contents/MacOS"
SIGNING_IDENTITY="${MACOS_SIGNING_IDENTITY:--}"

node "$ROOT/scripts/check-release-version.mjs"

cd "$ROOT"
swift build -c release --triple arm64-apple-macosx12.0
swift build -c release --triple x86_64-apple-macosx12.0

rm -rf "$APP"
mkdir -p "$MACOS"
lipo -create \
  "$ROOT/.build/arm64-apple-macosx/release/yc-onion" \
  "$ROOT/.build/x86_64-apple-macosx/release/yc-onion" \
  -output "$MACOS/yc-onion"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName YC Onion Controller" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.amirdaraee.yc-onion.controller" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.3.0" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 130" "$APP/Contents/Info.plist"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP" >/dev/null
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi

rm -f "$ARCHIVE"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

if [[ -n "${APPLE_ID:-}" || -n "${APPLE_TEAM_ID:-}" || -n "${APPLE_APP_PASSWORD:-}" ]]; then
  : "${APPLE_ID:?APPLE_ID is required for notarization}"
  : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required for notarization}"
  : "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required for notarization}"
  [[ "$SIGNING_IDENTITY" != "-" ]] || { echo "A Developer ID signing identity is required for notarization." >&2; exit 1; }
  xcrun notarytool submit "$ARCHIVE" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
  xcrun stapler staple "$APP"
  rm -f "$ARCHIVE"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
fi

rm -rf "$APP"

cd "$ROOT/streamdeck"
npm ci
npm run build
npm run pack

echo "One-click plugin created at:"
echo "$ROOT/streamdeck/dist/com.amirdaraee.yc-onion.streamDeckPlugin"
