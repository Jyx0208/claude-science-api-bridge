#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LABEL="com.byok.claude-science-proxy"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SYSTEMD_SERVICE_NAME="claude-science-api-bridge.service"
SYSTEMD_SERVICE="$HOME/.config/systemd/user/$SYSTEMD_SERVICE_NAME"
PID_FILE="$HOME/.claude-science/proxy.pid"
PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-9876}"
PROXY_URL="http://$PROXY_HOST:$PROXY_PORT"
DISPLAY_PROXY_URL="$PROXY_URL"
OS_NAME="$(uname -s)"

is_macos() {
  [ "$OS_NAME" = "Darwin" ]
}

is_linux() {
  [ "$OS_NAME" = "Linux" ]
}

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

mkdir -p "$HOME/.claude-science/logs"
if is_macos; then
  mkdir -p "$HOME/Library/LaunchAgents"
fi
if is_linux; then
  mkdir -p "$HOME/.config/systemd/user"
fi

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
    "MODEL_MENU_STRATEGY": "model_menu_strategy",
    "DEFAULT_MAX_TOKENS_CAP": "default_max_tokens_cap",
    "DEEPSEEK_UPSTREAM_MODE": "deepseek_upstream_mode",
    "OPENAI_UPSTREAM_MODE": "openai_upstream_mode",
    "CUSTOM_UPSTREAM_MODE": "custom_upstream_mode",
    "PROXY_AUTH_TOKEN": "proxy_auth_token",
    "PROXY_AUTH_MODE": "proxy_auth_mode",
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
    "MODEL_TOKEN_CAPS": "model_token_caps",
    "PROVIDER_PROFILES": "provider_profiles",
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

PROXY_URL="$("$PYTHON_BIN" - "$PROJECT_DIR/config.json" "$PROXY_HOST" "$PROXY_PORT" <<'PY'
import json
import sys
from pathlib import Path

cfg = json.loads(Path(sys.argv[1]).read_text())
url = f"http://{sys.argv[2]}:{sys.argv[3]}"
token = str(cfg.get("proxy_auth_token") or "").strip()
mode = str(cfg.get("proxy_auth_mode") or "optional").lower()
if token and mode == "required":
    url += "/" + token
print(url)
PY
)"
DISPLAY_PROXY_URL="$(printf '%s' "$PROXY_URL" | sed -E 's#(://[^/]+/).+#\1****#')"

if [ -f "$HOME/.claude-science/encryption.key" ]; then
  "$PYTHON_BIN" "$PROJECT_DIR/setup-token.py"
else
  echo "Warning: ~/.claude-science/encryption.key does not exist yet."
  if is_macos && [ -d "/Applications/Claude Science.app" ]; then
    echo "Opening Claude Science once to let it create local state..."
    open -a "Claude Science" >/dev/null 2>&1 || true
    sleep 8
  fi
  if [ -f "$HOME/.claude-science/encryption.key" ]; then
    "$PYTHON_BIN" "$PROJECT_DIR/setup-token.py"
  else
    echo "OAuth token was not generated because encryption.key is still missing."
    if is_macos; then
      echo "Agent action: open Claude Science once, wait for local files, then rerun ./scripts/install-safe.sh."
    else
      echo "Linux note: OAuth token generation is skipped unless a compatible client creates ~/.claude-science/encryption.key."
    fi
  fi
fi

if is_macos && [ "${DISABLE_DAEMON_AUTH_PATCH:-0}" != "1" ]; then
  PYTHON="$PYTHON_BIN" PROXY_PORT="$PROXY_PORT" "$PROJECT_DIR/scripts/patch-daemon-auth.sh" || {
    echo "Warning: Claude Science daemon auth patch was not applied."
    echo "Agent action: if Claude Science still shows logged-out, inspect docs/troubleshooting.md before changing network settings."
  }
elif is_macos; then
  echo "Daemon auth binary patch is disabled by DISABLE_DAEMON_AUTH_PATCH=1."
else
  echo "Skipping Claude Science daemon auth patch: Linux safe mode has no macOS daemon copy."
fi

if is_macos && [ "${DISABLE_DAEMON_MODEL_PATCH:-0}" != "1" ]; then
  PYTHON="$PYTHON_BIN" "$PROJECT_DIR/scripts/patch-daemon-models.sh" || {
    echo "Warning: Claude Science daemon model menu patch was not applied."
    echo "Agent action: Claude Science may still show Claude model names; inspect docs/troubleshooting.md."
  }
elif is_macos; then
  echo "Daemon model menu patch is disabled by DISABLE_DAEMON_MODEL_PATCH=1."
else
  echo "Skipping Claude Science daemon model patch: Linux safe mode has no macOS daemon copy."
fi

install_macos_service() {
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
}

install_linux_systemd_service() {
  cat > "$SYSTEMD_SERVICE" <<SERVICE
[Unit]
Description=Claude Science API Bridge
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$PROJECT_DIR
ExecStart=$PYTHON_BIN $PROJECT_DIR/proxy.py
Restart=always
RestartSec=3
Environment=ANTHROPIC_BASE_URL=$PROXY_URL
Environment=PROXY_HOST=$PROXY_HOST
Environment=PROXY_PORT=$PROXY_PORT
Environment=PATH=$(dirname "$PYTHON_BIN"):/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
SERVICE

  systemctl --user daemon-reload
  systemctl --user enable --now "$SYSTEMD_SERVICE_NAME"
}

start_linux_fallback_service() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
    echo "Fallback proxy process is already running: $(cat "$PID_FILE")"
    return 0
  fi
  (
    cd "$PROJECT_DIR"
    ANTHROPIC_BASE_URL="$PROXY_URL" \
    PROXY_HOST="$PROXY_HOST" \
    PROXY_PORT="$PROXY_PORT" \
    PATH="$(dirname "$PYTHON_BIN"):/usr/local/bin:/usr/bin:/bin" \
    nohup "$PYTHON_BIN" "$PROJECT_DIR/proxy.py" >>"$HOME/.claude-science/logs/proxy.log" 2>>"$HOME/.claude-science/logs/proxy-error.log" &
    echo $! > "$PID_FILE"
  )
  echo "Started fallback proxy process: $(cat "$PID_FILE")"
}

if is_macos; then
  install_macos_service
elif is_linux; then
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    install_linux_systemd_service
  else
    echo "systemd --user is unavailable; starting a per-user fallback background process."
    start_linux_fallback_service
  fi
else
  echo "Unsupported OS for service installation: $OS_NAME"
  echo "Start manually with: ANTHROPIC_BASE_URL=\"$DISPLAY_PROXY_URL\" $PYTHON_BIN \"$PROJECT_DIR/proxy.py\""
fi

sleep 2
curl -fsS "$PROXY_URL/health"
printf '\n'
echo "Safe install complete."
echo "Dashboard: http://$PROXY_HOST:$PROXY_PORT/dashboard"
if is_macos; then
  echo "Start Claude Science with: $PROJECT_DIR/scripts/start-claude-science.sh"
else
  echo "Use with compatible clients: export ANTHROPIC_BASE_URL=$DISPLAY_PROXY_URL"
fi
