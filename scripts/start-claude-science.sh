#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON_BIN="${PYTHON:-python3}"
PROXY_PORT="${PROXY_PORT:-9876}"
PROXY_URL="${ANTHROPIC_BASE_URL:-http://127.0.0.1:$PROXY_PORT}"

if [ -f "$HOME/.claude-science/encryption.key" ]; then
  "$PYTHON_BIN" "$PROJECT_DIR/setup-token.py" >/dev/null
fi

if [ "${DISABLE_DAEMON_AUTH_PATCH:-0}" != "1" ]; then
  PYTHON="$PYTHON_BIN" PROXY_PORT="$PROXY_PORT" "$SCRIPT_DIR/patch-daemon-auth.sh" >/dev/null || {
    echo "Warning: daemon auth patch failed; Claude Science may still show logged-out." >&2
  }
fi

if [ "${DISABLE_DAEMON_MODEL_PATCH:-0}" != "1" ]; then
  PYTHON="$PYTHON_BIN" "$SCRIPT_DIR/patch-daemon-models.sh" >/dev/null || {
    echo "Warning: daemon model menu patch failed; Claude Science may still show Claude model names." >&2
  }
fi

launchctl setenv ANTHROPIC_BASE_URL "$PROXY_URL"

pkill -f "claude-science serve" 2>/dev/null || true
pkill -f "ClaudeScience" 2>/dev/null || true
sleep 1
open -a "Claude Science"

echo "Started Claude Science with ANTHROPIC_BASE_URL=$PROXY_URL"
