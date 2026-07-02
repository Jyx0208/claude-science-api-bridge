#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

export PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
export PROXY_PORT="${PROXY_PORT:-9876}"

if [ ! -f "$SCRIPT_DIR/config.json" ] && [ -f "$SCRIPT_DIR/config.example.json" ]; then
  cp "$SCRIPT_DIR/config.example.json" "$SCRIPT_DIR/config.json"
  chmod 600 "$SCRIPT_DIR/config.json"
fi

if [ -f "$HOME/.claude-science/encryption.key" ]; then
  python3 "$SCRIPT_DIR/setup-token.py"
else
  echo "Warning: ~/.claude-science/encryption.key does not exist yet."
  echo "Open Claude Science once, then rerun setup-token.py if login state is needed."
fi

echo "Dashboard: http://$PROXY_HOST:$PROXY_PORT/dashboard"
echo "Health:    http://$PROXY_HOST:$PROXY_PORT/health"
echo "Use:       export ANTHROPIC_BASE_URL=http://$PROXY_HOST:$PROXY_PORT"
echo

exec python3 "$SCRIPT_DIR/proxy.py"

