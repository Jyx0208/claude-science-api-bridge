#!/usr/bin/env bash
set -euo pipefail

PROXY_URL="${ANTHROPIC_BASE_URL:-http://127.0.0.1:${PROXY_PORT:-9876}}"
launchctl setenv ANTHROPIC_BASE_URL "$PROXY_URL"

pkill -f "claude-science serve" 2>/dev/null || true
pkill -f "ClaudeScience" 2>/dev/null || true
sleep 1
open -a "Claude Science"

echo "Started Claude Science with ANTHROPIC_BASE_URL=$PROXY_URL"

