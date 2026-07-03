#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_NAME="Claude Science API Bridge"
APP_BUNDLE="$PROJECT_DIR/dist/$APP_NAME.app"
DMG_PATH="$PROJECT_DIR/dist/$APP_NAME.dmg"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"

rm -rf "$APP_BUNDLE" "$DMG_PATH"
mkdir -p "$RESOURCES_DIR/proxy" "$MACOS_DIR"

rsync -a "$PROJECT_DIR/" "$RESOURCES_DIR/proxy/" \
  --exclude .git \
  --exclude dist \
  --exclude config.json \
  --exclude certs \
  --exclude .env \
  --exclude .env.* \
  --exclude .venv \
  --exclude venv \
  --exclude __pycache__ \
  --exclude "tests/__pycache__" \
  --exclude "*.pyc" \
  --exclude "*.plist" \
  --exclude "*.log" \
  --exclude ".daemon-model-patch.json"

cp "$SCRIPT_DIR/app-launcher.sh" "$MACOS_DIR/ClaudeScienceAPIBridge"
chmod +x "$MACOS_DIR/ClaudeScienceAPIBridge"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Science API Bridge</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeScienceAPIBridge</string>
    <key>CFBundleIdentifier</key>
    <string>com.byok.claude-science-api-bridge</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Claude Science API Bridge</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.3</string>
    <key>CFBundleVersion</key>
    <string>0.2.3</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
fi

if command -v hdiutil >/dev/null 2>&1; then
  hdiutil create -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DMG_PATH" >/dev/null
  echo "Built app: $APP_BUNDLE"
  echo "Built dmg: $DMG_PATH"
else
  echo "Built app: $APP_BUNDLE"
  echo "hdiutil not found; skipped DMG creation."
fi
