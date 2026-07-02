#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LABEL="com.byok.claude-science-proxy"
PORT="${PROXY_PORT:-9876}"

section() {
  printf '\n== %s ==\n' "$1"
}

exists() {
  command -v "$1" >/dev/null 2>&1
}

section "System"
sw_vers 2>/dev/null || true
printf 'User: %s\n' "$(id -un)"
printf 'Project: %s\n' "$PROJECT_DIR"

section "Python"
if exists python3; then
  printf 'python3: %s\n' "$(command -v python3)"
  python3 --version
else
  printf 'python3: missing\n'
fi

section "Claude Science"
if [ -d "/Applications/Claude Science.app" ]; then
  printf 'App: installed\n'
else
  printf 'App: not found at /Applications/Claude Science.app\n'
fi
ps aux | grep -E 'ClaudeScience|claude-science serve' | grep -v grep || true
lsof -nP -iTCP:8765 -sTCP:LISTEN 2>/dev/null || true

section "Launchctl Environment"
printf 'ANTHROPIC_BASE_URL=%s\n' "$(launchctl getenv ANTHROPIC_BASE_URL || true)"
printf 'NODE_EXTRA_CA_CERTS=%s\n' "$(launchctl getenv NODE_EXTRA_CA_CERTS || true)"
printf 'SSL_CERT_FILE=%s\n' "$(launchctl getenv SSL_CERT_FILE || true)"

section "Proxy Service"
launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E 'state =|pid =|path =|program =|last exit code' || true
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true
lsof -nP -iTCP:9877 -sTCP:LISTEN 2>/dev/null || true
lsof -nP -iTCP:443 -sTCP:LISTEN 2>/dev/null || true

section "Files"
for path in \
  "$PROJECT_DIR/proxy.py" \
  "$PROJECT_DIR/setup-token.py" \
  "$PROJECT_DIR/config.json" \
  "$PROJECT_DIR/config.example.json" \
  "$HOME/.claude-science/encryption.key"; do
  if [ -e "$path" ]; then
    printf 'ok   %s\n' "$path"
  else
    printf 'miss %s\n' "$path"
  fi
done

section "Config Summary"
if [ -f "$PROJECT_DIR/config.json" ] && exists python3; then
  PROJECT_DIR="$PROJECT_DIR" python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["PROJECT_DIR"]) / "config.json"
data = json.loads(path.read_text())

def configured(key):
    return "yes" if bool(data.get(key)) else "no"

print(f"default_backend={data.get('default_backend', '')}")
print(f"force_model={data.get('force_model', '')}")
print(f"model_list_mode={data.get('model_list_mode', '')}")
print(f"model_aliases={len(data.get('model_aliases') or [])}")
print(f"deepseek_upstream_mode={data.get('deepseek_upstream_mode', '')}")
print(f"openai_upstream_mode={data.get('openai_upstream_mode', '')}")
print(f"custom_upstream_mode={data.get('custom_upstream_mode', '')}")
print(f"proxy_auth_mode={data.get('proxy_auth_mode', '')}")
print(f"proxy_auth_token={'yes' if data.get('proxy_auth_token') else 'no'}")
print(f"deepseek_api_key={configured('deepseek_api_key')}")
print(f"openai_api_key={configured('openai_api_key')}")
print(f"custom_api_key={configured('custom_api_key')}")
print(f"custom_base_url={data.get('custom_base_url', '')}")
print(f"reasoning_content_policy={data.get('reasoning_content_policy', '')}")
PY
else
  printf 'config.json not readable\n'
fi

section "HTTP Checks"
curl -fsS --max-time 3 "http://127.0.0.1:$PORT/health" || true
printf '\n'
curl -fsS --max-time 3 "http://127.0.0.1:$PORT/api/recent-requests" | head -c 2000 || true
printf '\n'

section "Recent Logs"
tail -n 40 "$HOME/.claude-science/logs/proxy.log" 2>/dev/null || true
tail -n 40 "$HOME/.claude-science/logs/proxy-error.log" 2>/dev/null || true
