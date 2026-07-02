#!/usr/bin/env bash
set -euo pipefail

PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-9876}"
BASE_URL="http://$PROXY_HOST:$PROXY_PORT"
PYTHON="${PYTHON:-python3}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Verifying proxy at $BASE_URL"

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

echo "proxy verification passed"
