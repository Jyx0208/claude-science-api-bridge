#!/usr/bin/env bash
set -euo pipefail

APP_MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_CONTENTS_DIR="$(cd "$APP_MACOS_DIR/.." && pwd)"
BUNDLED_PROJECT_DIR="$APP_CONTENTS_DIR/Resources/proxy"
INSTALL_DIR="$HOME/.claude-science/proxy"
LOG_DIR="$HOME/.claude-science/logs"
LOG_FILE="$LOG_DIR/bridge-app.log"

mkdir -p "$LOG_DIR"
exec >>"$LOG_FILE" 2>&1

echo "==== Claude Science API Bridge launch $(date) ===="

alert() {
  /usr/bin/osascript -e "display dialog \"$1\" buttons {\"OK\"} default button \"OK\" with title \"Claude Science API Bridge\"" >/dev/null 2>&1 || true
}

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"Claude Science API Bridge\"" >/dev/null 2>&1 || true
}

ask_text() {
  local prompt="$1"
  local default_value="${2:-}"
  local hidden="${3:-0}"
  if [ "$hidden" = "1" ]; then
    /usr/bin/osascript -e "text returned of (display dialog \"$prompt\" default answer \"$default_value\" with hidden answer buttons {\"Cancel\", \"OK\"} default button \"OK\" with title \"Claude Science API Bridge\")"
  else
    /usr/bin/osascript -e "text returned of (display dialog \"$prompt\" default answer \"$default_value\" buttons {\"Cancel\", \"OK\"} default button \"OK\" with title \"Claude Science API Bridge\")"
  fi
}

choose_provider() {
  /usr/bin/osascript <<'OSA'
set choices to {"SiliconFlow Kimi", "DeepSeek", "OpenAI", "Custom"}
set picked to choose from list choices with prompt "请选择第三方 API Provider" default items {"SiliconFlow Kimi"} with title "Claude Science API Bridge"
if picked is false then
  return ""
end if
return item 1 of picked
OSA
}

find_python() {
  for candidate in /opt/miniconda3/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

sync_project() {
  if [ ! -d "$BUNDLED_PROJECT_DIR" ]; then
    alert "发布包损坏：找不到内置 proxy 目录。"
    exit 1
  fi

  mkdir -p "$INSTALL_DIR"
  /usr/bin/rsync -a \
    --exclude config.json \
    --exclude certs \
    --exclude .env \
    --exclude .env.* \
    --exclude .git \
    --exclude .venv \
    --exclude venv \
    --exclude __pycache__ \
    --exclude "tests/__pycache__" \
    --exclude "*.pyc" \
    --exclude "*.plist" \
    --exclude "*.log" \
    --exclude ".daemon-model-patch.json" \
    "$BUNDLED_PROJECT_DIR/" "$INSTALL_DIR/"
}

configure_if_needed() {
  local python_bin="$1"
  if [ ! -f "$INSTALL_DIR/config.json" ]; then
    cp "$INSTALL_DIR/config.example.json" "$INSTALL_DIR/config.json"
    chmod 600 "$INSTALL_DIR/config.json"
  fi

  local configured
  configured="$("$python_bin" - "$INSTALL_DIR/config.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
keys = ("deepseek_api_key", "openai_api_key", "custom_api_key")
print("yes" if any(data.get(k) for k in keys) else "no")
PY
)"
  if [ "$configured" = "yes" ]; then
    return 0
  fi

  local provider api_key base_url model backend mode inline_policy display_name
  provider="$(choose_provider)"
  if [ -z "$provider" ]; then
    alert "已取消配置。下次打开 App 可继续。"
    exit 0
  fi

  api_key="$(ask_text "请输入你的 $provider API Key。它只会保存到本机 config.json，不会显示在日志里。" "" 1)"
  if [ -z "$api_key" ]; then
    alert "API Key 为空，已取消配置。"
    exit 0
  fi

  case "$provider" in
    "SiliconFlow Kimi")
      backend="custom"
      base_url="https://api.siliconflow.cn"
      model="Pro/moonshotai/Kimi-K2.6"
      mode="openai"
      inline_policy="preserve"
      display_name="Kimi K2.6 Pro++"
      ;;
    "DeepSeek")
      backend="deepseek"
      base_url="https://api.deepseek.com"
      model="deepseek-chat"
      mode="openai"
      inline_policy="auto"
      display_name="DeepSeek Chat"
      ;;
    "OpenAI")
      backend="openai"
      base_url="https://api.openai.com"
      model="gpt-4o"
      mode="openai"
      inline_policy="preserve"
      display_name="GPT-4o"
      ;;
    *)
      backend="custom"
      base_url="$(ask_text "请输入 OpenAI-compatible Base URL" "https://provider.example.com" 0)"
      model="$(ask_text "请输入实际模型名" "provider-model-name" 0)"
      mode="openai"
      inline_policy="auto"
      display_name="$model"
      ;;
  esac

  PROVIDER="$provider" API_KEY="$api_key" BACKEND="$backend" BASE_URL="$base_url" MODEL="$model" MODE="$mode" INLINE_POLICY="$inline_policy" DISPLAY_NAME="$display_name" "$python_bin" - "$INSTALL_DIR/config.json" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
backend = os.environ["BACKEND"]
api_key = os.environ["API_KEY"]
base_url = os.environ["BASE_URL"]
model = os.environ["MODEL"]
mode = os.environ["MODE"]
inline_policy = os.environ["INLINE_POLICY"]
display_name = os.environ["DISPLAY_NAME"]

data["default_backend"] = backend
data["force_model"] = model
data["model_list_mode"] = "aliases"
data["reasoning_content_policy"] = "never"
data["inline_image_policy"] = inline_policy
data["model_aliases"] = [
    {"id": "byok-model-0001", "display_name": display_name, "backend": backend, "model": model},
    {"id": "byok-model-0002", "display_name": "BYOK Model 0002", "backend": backend, "model": model},
    {"id": "byok-model-000003", "display_name": "BYOK Model 000003", "backend": backend, "model": model},
]
if backend == "deepseek":
    data["deepseek_api_key"] = api_key
    data["deepseek_base_url"] = base_url
    data["deepseek_upstream_mode"] = mode
elif backend == "openai":
    data["openai_api_key"] = api_key
    data["openai_base_url"] = base_url
    data["openai_upstream_mode"] = mode
else:
    data["custom_api_key"] = api_key
    data["custom_base_url"] = base_url
    data["custom_upstream_mode"] = mode

path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
path.chmod(0o600)
PY
}

main() {
  notify "正在安装并启动本地代理..."
  sync_project

  local python_bin
  python_bin="$(find_python)" || {
    alert "找不到 python3。请先安装 Python 3 后重新打开。"
    exit 1
  }

  configure_if_needed "$python_bin"

  cd "$INSTALL_DIR"
  PYTHON="$python_bin" ./scripts/install-safe.sh

  /usr/bin/open "http://127.0.0.1:9876/dashboard" >/dev/null 2>&1 || true
  PYTHON="$python_bin" ./scripts/start-claude-science.sh || true

  alert "安装完成。已启动本地代理并打开 Dashboard。"
}

main "$@"
