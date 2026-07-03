#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Claude Science API Bridge"
APP_BUNDLE="$APP_NAME.app"
DMG_URL="${DMG_URL:-https://github.com/Jyx0208/claude-science-api-bridge/releases/latest/download/Claude.Science.API.Bridge.dmg}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
TARGET_APP="$INSTALL_DIR/$APP_BUNDLE"
TMP_DIR="$(mktemp -d)"
MOUNT_POINT=""

cleanup() {
  if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat <<'TEXT'
Claude Science API Bridge macOS installer

This helper downloads the latest DMG, copies the app to ~/Applications,
removes Apple's quarantine attribute, and opens the app.

Use this only if you trust this open-source project and downloaded it from:
https://github.com/Jyx0208/claude-science-api-bridge
TEXT

mkdir -p "$INSTALL_DIR"

DMG_PATH="$TMP_DIR/$APP_NAME.dmg"
echo "Downloading: $DMG_URL"
curl -fL --retry 3 --connect-timeout 15 "$DMG_URL" -o "$DMG_PATH"

echo "Mounting DMG..."
MOUNT_POINT="$(hdiutil attach "$DMG_PATH" -nobrowse -quiet | awk '/\\/Volumes\\// {print substr($0, index($0, "/Volumes/")); exit}')"
if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT" ]; then
  echo "Could not determine mounted DMG volume." >&2
  exit 1
fi

SOURCE_APP="$(find "$MOUNT_POINT" -maxdepth 2 -name "$APP_BUNDLE" -type d | head -1)"
if [ -z "$SOURCE_APP" ]; then
  echo "App bundle not found in DMG." >&2
  exit 1
fi

echo "Installing to: $TARGET_APP"
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"

echo "Removing quarantine attribute from installed app..."
xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true

echo "Opening app..."
open "$TARGET_APP"

cat <<TEXT

Done.

Installed app:
  $TARGET_APP

If macOS still shows a security prompt, open System Settings > Privacy & Security
and click "Open Anyway", or run:

  xattr -dr com.apple.quarantine "$TARGET_APP"
  open "$TARGET_APP"
TEXT
