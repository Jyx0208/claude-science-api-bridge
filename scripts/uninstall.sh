#!/usr/bin/env bash
set -euo pipefail

LABEL="com.byok.claude-science-proxy"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SYSTEMD_SERVICE_NAME="claude-science-api-bridge.service"
SYSTEMD_SERVICE="$HOME/.config/systemd/user/$SYSTEMD_SERVICE_NAME"
PID_FILE="$HOME/.claude-science/proxy.pid"
OS_NAME="$(uname -s)"

if [ "$OS_NAME" = "Darwin" ]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  launchctl remove "$LABEL" >/dev/null 2>&1 || true
  rm -f "$PLIST"

  launchctl unsetenv ANTHROPIC_BASE_URL >/dev/null 2>&1 || true

  echo "Removed $LABEL LaunchAgent and ANTHROPIC_BASE_URL launchctl environment."
elif [ "$OS_NAME" = "Linux" ]; then
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now "$SYSTEMD_SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_SERVICE"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "$PID_FILE"
  fi
  echo "Removed Linux user service/fallback process."
else
  echo "No service uninstaller is defined for $OS_NAME."
fi
echo "Left config.json, API keys, tokens, and logs in place."
