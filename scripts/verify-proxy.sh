#!/usr/bin/env bash
set -euo pipefail

PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-9876}"
BASE_URL="http://$PROXY_HOST:$PROXY_PORT"
PYTHON="${PYTHON:-python3}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [ -f "config.json" ]; then
  BASE_URL="$("$PYTHON" - "config.json" "$PROXY_HOST" "$PROXY_PORT" <<'PY'
import json
import sys
from pathlib import Path

cfg = json.loads(Path(sys.argv[1]).read_text())
host = str(cfg.get("proxy_host") or sys.argv[2])
port = str(cfg.get("proxy_port") or sys.argv[3])
url = f"http://{host}:{port}"
token = str(cfg.get("proxy_auth_token") or "").strip()
mode = str(cfg.get("proxy_auth_mode") or "optional").lower()
if token and mode == "required":
    url += "/" + token
print(url)
PY
)"
fi
DISPLAY_BASE_URL="$(printf '%s' "$BASE_URL" | sed -E 's#(://[^/]+/).+#\1****#')"

echo "Verifying proxy at $DISPLAY_BASE_URL"

echo "1. health"
curl -fsS --max-time 5 "$BASE_URL/health" > "$TMP_DIR/health.json"
"$PYTHON" - <<PY
import json
from pathlib import Path
data = json.loads(Path("$TMP_DIR/health.json").read_text())
assert data.get("status") == "ok", data
configured = data.get("deepseek_configured") or data.get("openai_configured") or data.get("custom_configured")
if not configured:
    raise SystemExit("No backend API key is configured. Configure config.json or dashboard first.")
print(json.dumps(data, ensure_ascii=False))
PY

echo "2. models"
curl -fsS --max-time 5 "$BASE_URL/v1/models" > "$TMP_DIR/models.json"
"$PYTHON" - <<PY
import json
from pathlib import Path
data = json.loads(Path("$TMP_DIR/models.json").read_text())
assert isinstance(data.get("data"), list) and data["data"], data
print(f"models={len(data['data'])}")
PY

echo "3. messages"
STATUS="$(curl -sS --max-time 60 -o "$TMP_DIR/message.json" -w "%{http_code}" \
  "$BASE_URL/v1/messages" \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-sonnet-4-5","max_tokens":32,"messages":[{"role":"user","content":"Reply with OK."}]}')"
if [ "$STATUS" -lt 200 ] || [ "$STATUS" -ge 300 ]; then
  echo "Message request failed with HTTP $STATUS"
  head -c 1000 "$TMP_DIR/message.json"
  echo
  exit 1
fi
"$PYTHON" - <<PY
import json
from pathlib import Path
data = json.loads(Path("$TMP_DIR/message.json").read_text())
if data.get("type") == "error" or data.get("error"):
    raise SystemExit(json.dumps(data, ensure_ascii=False)[:1000])
assert data.get("type") == "message", data
assert isinstance(data.get("content"), list), data
print(f"message_id={data.get('id')} stop_reason={data.get('stop_reason')}")
PY

echo "4. recent requests"
curl -fsS --max-time 5 "$BASE_URL/api/recent-requests" > "$TMP_DIR/recent.json"
"$PYTHON" - <<PY
import json
from pathlib import Path
data = json.loads(Path("$TMP_DIR/recent.json").read_text())
requests = data.get("requests", [])
success = [r for r in requests if r.get("backend") in {"deepseek", "openai", "custom"} and r.get("status") == "success"]
if not success:
    raise SystemExit("No successful backend request found in recent requests.")
print(f"successful_backend_requests={len(success)}")
PY

if [ "${VERIFY_IMAGE:-0}" = "1" ]; then
  echo "5. image message"
  if ! command -v sips >/dev/null 2>&1; then
    echo "sips is required for VERIFY_IMAGE=1 on macOS."
    exit 1
  fi
  "$PYTHON" - <<'PY' > "$TMP_DIR/red.ppm"
w = h = 128
print(f"P3\n{w} {h}\n255")
for _ in range(w * h):
    print("255 0 0")
PY
  sips -s format png "$TMP_DIR/red.ppm" --out "$TMP_DIR/red.png" >/dev/null
  IMG_B64="$(base64 < "$TMP_DIR/red.png" | tr -d '\n')"
  IMG_B64="$IMG_B64" "$PYTHON" - <<'PY' > "$TMP_DIR/image-request.json"
import json
import os

print(json.dumps({
    "model": "claude-opus-4-8",
    "max_tokens": 32,
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "Look at the image. If the dominant color is red, reply exactly: red. Otherwise reply exactly: no."},
            {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": os.environ["IMG_B64"]}},
        ],
    }],
}))
PY
  STATUS="$(curl -sS --max-time 90 -o "$TMP_DIR/image-message.json" -w "%{http_code}" \
    "$BASE_URL/v1/messages" \
    -H 'Content-Type: application/json' \
    -d @"$TMP_DIR/image-request.json")"
  if [ "$STATUS" -lt 200 ] || [ "$STATUS" -ge 300 ]; then
    echo "Image request failed with HTTP $STATUS"
    head -c 1000 "$TMP_DIR/image-message.json"
    echo
    exit 1
  fi
  "$PYTHON" - <<PY
import json
import re
from pathlib import Path

data = json.loads(Path("$TMP_DIR/image-message.json").read_text())
text = " ".join(part.get("text", "") for part in data.get("content", []) if isinstance(part, dict))
if not re.search(r"\\b(red)\\b|红|赤", text, re.I):
    raise SystemExit(f"Image verification did not confirm red. Response: {text[:300]!r}")
print(f"image_response={text[:120]}")
PY
fi

echo "proxy verification passed"
