#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LABEL="com.byok.claude-science-proxy"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-9876}"
PROXY_URL="http://$PROXY_HOST:$PROXY_PORT"

find_python() {
  if [ -n "${PYTHON:-}" ] && [ -x "$PYTHON" ]; then
    printf '%s\n' "$PYTHON"
    return
  fi
  for candidate in /opt/miniconda3/bin/python3 /usr/local/bin/python3 /opt/homebrew/bin/python3 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return
    fi
  done
  return 1
}

PYTHON_BIN="$(find_python)" || {
  echo "python3 not found. Install Python 3 first."
  exit 1
}

mkdir -p "$HOME/.claude-science/logs" "$HOME/Library/LaunchAgents"

echo "Using Python: $PYTHON_BIN"
"$PYTHON_BIN" -m pip install -r "$PROJECT_DIR/requirements.txt"

if [ ! -f "$PROJECT_DIR/config.json" ]; then
  cp "$PROJECT_DIR/config.example.json" "$PROJECT_DIR/config.json"
  chmod 600 "$PROJECT_DIR/config.json"
  echo "Created config.json from config.example.json"
fi

if [ -f "$HOME/.claude-science/encryption.key" ]; then
  "$PYTHON_BIN" "$PROJECT_DIR/setup-token.py"
else
  echo "Warning: ~/.claude-science/encryption.key does not exist yet."
  echo "Open Claude Science once, then rerun this script to generate the OAuth token."
fi

launchctl setenv ANTHROPIC_BASE_URL "$PROXY_URL"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON_BIN</string>
        <string>$PROJECT_DIR/proxy.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$PROJECT_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>ANTHROPIC_BASE_URL</key>
        <string>$PROXY_URL</string>
        <key>PROXY_HOST</key>
        <string>$PROXY_HOST</string>
        <key>PROXY_PORT</key>
        <string>$PROXY_PORT</string>
        <key>PATH</key>
        <string>$(dirname "$PYTHON_BIN"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$HOME/.claude-science/logs/proxy.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.claude-science/logs/proxy-error.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || launchctl load "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true

sleep 2
curl -fsS "$PROXY_URL/health"
printf '\n'
echo "Safe install complete."
echo "Dashboard: $PROXY_URL/dashboard"
echo "Start Claude Science with: open -a \"Claude Science\""

