#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="Claude Science API Bridge"
APP_BUNDLE="$PROJECT_DIR/dist/$APP_NAME.app"
DMG_PATH="$PROJECT_DIR/dist/$APP_NAME.dmg"
IDENTITY="${DEVELOPER_ID_APPLICATION:-${CODESIGN_IDENTITY:-}}"
NOTARY_PROFILE="${NOTARYTOOL_PROFILE:-}"

if [ -z "$IDENTITY" ]; then
  cat >&2 <<'TEXT'
Missing Developer ID signing identity.

Set one of:
  DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
  CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"

You need an Apple Developer Program account and a Developer ID Application certificate.
TEXT
  exit 2
fi

for tool in codesign hdiutil xcrun; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required tool: $tool" >&2
    exit 2
  }
done

"$PROJECT_DIR/scripts/build-macos-release.sh" >/dev/null

echo "Signing app with Developer ID: $IDENTITY"
codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DMG_PATH" >/dev/null

echo "Signing DMG with Developer ID: $IDENTITY"
codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

echo "Submitting DMG to Apple notary service..."
if [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
else
  : "${APPLE_ID:?Set APPLE_ID or NOTARYTOOL_PROFILE}"
  : "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID or NOTARYTOOL_PROFILE}"
  : "${APPLE_APP_PASSWORD:?Set APPLE_APP_PASSWORD or NOTARYTOOL_PROFILE}"
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
fi

echo "Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "Assessing notarized artifacts..."
spctl -a -vv "$APP_BUNDLE"
spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"

echo "Notarized release package:"
echo "  $DMG_PATH"
