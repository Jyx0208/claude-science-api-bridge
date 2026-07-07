#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="${CCSWITCH_BACKUP_ROOT:-$HOME/.claude-science/ccswitch-backups}"
BACKUP_DIR="${CCSWITCH_RESTORE_BACKUP:-}"
DEST_APP="${CCSWITCH_RESTORE_DEST:-}"
OPEN_AFTER=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)
      BACKUP_DIR="${2:-}"
      shift 2
      ;;
    --dest)
      DEST_APP="${2:-}"
      shift 2
      ;;
    --no-open)
      OPEN_AFTER=0
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "CC Switch restore is currently macOS-only." >&2
  exit 1
fi

if [[ -z "$BACKUP_DIR" ]]; then
  if [[ -d "$BACKUP_ROOT" ]]; then
    BACKUP_DIR="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)"
  else
    BACKUP_DIR=""
  fi
fi

if [[ -z "$BACKUP_DIR" || ! -d "$BACKUP_DIR/CC Switch.app" ]]; then
  echo "No CC Switch backup found under $BACKUP_ROOT." >&2
  exit 1
fi

if [[ -z "$DEST_APP" && -f "$BACKUP_DIR/metadata.json" ]]; then
  DEST_APP="$(python3 - "$BACKUP_DIR/metadata.json" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("dest_app") or "")
except Exception:
    print("")
PY
)"
fi

if [[ -z "$DEST_APP" ]]; then
  if [[ -d "/Applications/CC Switch.app" ]]; then
    DEST_APP="/Applications/CC Switch.app"
  else
    DEST_APP="$HOME/Applications/CC Switch.app"
  fi
fi

echo "Stopping CC Switch if it is running..."
osascript -e 'tell application "CC Switch" to quit' >/dev/null 2>&1 || true
sleep 2

echo "Restoring CC Switch from $BACKUP_DIR/CC Switch.app"
mkdir -p "$(dirname "$DEST_APP")"
rm -rf "$DEST_APP"
ditto "$BACKUP_DIR/CC Switch.app" "$DEST_APP"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 "$DEST_APP" >/dev/null 2>&1 || true

if [[ "$OPEN_AFTER" -eq 1 ]]; then
  echo "Opening restored CC Switch..."
  open "$DEST_APP"
fi

echo "CC Switch restored."
echo "Installed: $DEST_APP"
echo "Backup: $BACKUP_DIR/CC Switch.app"
