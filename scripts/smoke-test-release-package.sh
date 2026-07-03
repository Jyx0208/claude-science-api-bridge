#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BIN="$PROJECT_DIR/dist/Claude Science API Bridge.app/Contents/MacOS/ClaudeScienceAPIBridge"
PYTHON="${PYTHON:-python3}"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

"$PROJECT_DIR/scripts/build-macos-release.sh" >/dev/null

if [ ! -x "$APP_BIN" ]; then
  echo "App binary not found: $APP_BIN"
  exit 1
fi

HOME="$TMP_HOME" \
BRIDGE_NONINTERACTIVE=1 \
BRIDGE_DRY_RUN=1 \
BRIDGE_PROVIDER="SiliconFlow Kimi" \
BRIDGE_API_KEY="test-release-key" \
"$APP_BIN"

CONFIG="$TMP_HOME/.claude-science/proxy/config.json"
if [ ! -f "$CONFIG" ]; then
  echo "config.json was not generated"
  exit 1
fi

"$PYTHON" - "$TMP_HOME" <<'PY'
import json
import os
import stat
import sys
from pathlib import Path

home = Path(sys.argv[1])
install = home / ".claude-science" / "proxy"
config = install / "config.json"
data = json.loads(config.read_text())
mode = stat.S_IMODE(config.stat().st_mode)
assert mode == 0o600, oct(mode)
assert data["default_backend"] == "custom", data
assert data["custom_base_url"] == "https://api.siliconflow.cn", data
assert data["custom_upstream_mode"] == "openai", data
assert data["force_model"] == "Pro/moonshotai/Kimi-K2.6", data
assert data["model_aliases"][0]["display_name"] == "Kimi K2.6 Pro++ (Vision)", data
assert data["custom_api_key"] == "test-release-key", data

for rel in [
    "certs/ca-key.pem",
    "certs/server-key.pem",
    ".env",
    ".git",
    ".daemon-model-patch.json",
]:
    assert not (install / rel).exists(), rel

print("release package smoke test passed")
PY
