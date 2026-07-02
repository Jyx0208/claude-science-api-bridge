#!/usr/bin/env bash
set -euo pipefail

LABEL="com.byok.claude-science-proxy"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl remove "$LABEL" >/dev/null 2>&1 || true
rm -f "$PLIST"

launchctl unsetenv ANTHROPIC_BASE_URL >/dev/null 2>&1 || true

echo "Removed $LABEL LaunchAgent and ANTHROPIC_BASE_URL launchctl environment."
echo "Left config.json, API keys, tokens, and logs in place."

