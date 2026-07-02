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

BOOTSTRAP_PYTHON="$(find_python)" || {
  echo "python3 not found. Install Python 3 first."
  exit 1
}
VENV_DIR="${VENV_DIR:-$PROJECT_DIR/.venv}"

mkdir -p "$HOME/.claude-science/logs" "$HOME/Library/LaunchAgents"

echo "Using bootstrap Python: $BOOTSTRAP_PYTHON"
if [ "${USE_SYSTEM_PYTHON:-0}" = "1" ]; then
  PYTHON_BIN="$BOOTSTRAP_PYTHON"
else
  if [ ! -x "$VENV_DIR/bin/python" ]; then
    "$BOOTSTRAP_PYTHON" -m venv "$VENV_DIR" || {
      echo "Warning: could not create venv. Falling back to bootstrap Python."
      PYTHON_BIN="$BOOTSTRAP_PYTHON"
    }
  fi
  PYTHON_BIN="${PYTHON_BIN:-$VENV_DIR/bin/python}"
fi

echo "Using runtime Python: $PYTHON_BIN"
"$PYTHON_BIN" -m pip install --upgrade pip >/dev/null
"$PYTHON_BIN" -m pip install -r "$PROJECT_DIR/requirements.txt"

if [ ! -f "$PROJECT_DIR/config.json" ]; then
  cp "$PROJECT_DIR/config.example.json" "$PROJECT_DIR/config.json"
  chmod 600 "$PROJECT_DIR/config.json"
  echo "Created config.json from config.example.json"
fi

PROJECT_DIR="$PROJECT_DIR" "$PYTHON_BIN" - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["PROJECT_DIR"]) / "config.json"
data = json.loads(path.read_text())
mapping = {
    "DEEPSEEK_API_KEY": "deepseek_api_key",
    "OPENAI_API_KEY": "openai_api_key",
    "CUSTOM_API_KEY": "custom_api_key",
    "DEEPSEEK_BASE_URL": "deepseek_base_url",
    "OPENAI_BASE_URL": "openai_base_url",
    "CUSTOM_BASE_URL": "custom_base_url",
    "DEFAULT_BACKEND": "default_backend",
    "FORCE_MODEL": "force_model",
    "MODEL_LIST_MODE": "model_list_mode",
    "REASONING_CONTENT_POLICY": "reasoning_content_policy",
    "INLINE_IMAGE_POLICY": "inline_image_policy",
}
changed = []
for env_key, config_key in mapping.items():
    value = os.environ.get(env_key)
    if value:
        data[config_key] = value
        changed.append(config_key)
for env_key, config_key in {
    "DEEPSEEK_MODEL_MAP": "deepseek_model_map",
    "OPENAI_MODEL_MAP": "openai_model_map",
    "CUSTOM_MODEL_MAP": "custom_model_map",
    "MODEL_ALIASES": "model_aliases",
}.items():
    value = os.environ.get(env_key)
    if value:
        data[config_key] = json.loads(value)
        changed.append(config_key)
if changed:
    path.write_text(json.dumps(data, indent=2) + "\n")
    path.chmod(0o600)
    safe_changed = [k for k in changed if not k.endswith("_api_key")]
    secret_count = sum(1 for k in changed if k.endswith("_api_key"))
    print(f"Applied config from environment: {', '.join(safe_changed) or '(only secrets)'}; secrets updated: {secret_count}")
PY

if [ -f "$HOME/.claude-science/encryption.key" ]; then
  "$PYTHON_BIN" "$PROJECT_DIR/setup-token.py"
else
  echo "Warning: ~/.claude-science/encryption.key does not exist yet."
  if [ -d "/Applications/Claude Science.app" ]; then
    echo "Opening Claude Science once to let it create local state..."
    open -a "Claude Science" >/dev/null 2>&1 || true
    sleep 8
  fi
  if [ -f "$HOME/.claude-science/encryption.key" ]; then
    "$PYTHON_BIN" "$PROJECT_DIR/setup-token.py"
  else
    echo "OAuth token was not generated because encryption.key is still missing."
    echo "Agent action: open Claude Science once, wait for local files, then rerun ./scripts/install-safe.sh."
  fi
fi

if [ "${DISABLE_DAEMON_AUTH_PATCH:-0}" != "1" ]; then
  PYTHON="$PYTHON_BIN" PROXY_PORT="$PROXY_PORT" "$PROJECT_DIR/scripts/patch-daemon-auth.sh" || {
    echo "Warning: Claude Science daemon auth patch was not applied."
    echo "Agent action: if Claude Science still shows logged-out, inspect docs/troubleshooting.md before changing network settings."
  }
else
  echo "Daemon auth binary patch is disabled by DISABLE_DAEMON_AUTH_PATCH=1."
fi

if [ "${DISABLE_DAEMON_MODEL_PATCH:-0}" != "1" ]; then
  PYTHON="$PYTHON_BIN" "$PROJECT_DIR/scripts/patch-daemon-models.sh" || {
    echo "Warning: Claude Science daemon model menu patch was not applied."
    echo "Agent action: Claude Science may still show Claude model names; inspect docs/troubleshooting.md."
  }
else
  echo "Daemon model menu patch is disabled by DISABLE_DAEMON_MODEL_PATCH=1."
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
echo "Start Claude Science with: $PROJECT_DIR/scripts/start-claude-science.sh"
