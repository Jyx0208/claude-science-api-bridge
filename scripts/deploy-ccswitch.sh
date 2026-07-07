#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${BRIDGE_GITHUB_REPO:-Jyx0208/claude-science-api-bridge}"
ZIP_URL="${CCSWITCH_PATCHED_ZIP_URL:-https://github.com/$REPO/releases/latest/download/CC-Switch-Claude-Science-aarch64.zip}"
BACKUP_ROOT="${CCSWITCH_BACKUP_ROOT:-$HOME/.claude-science/ccswitch-backups}"
INSTALL_DIR="${CCSWITCH_INSTALL_DIR:-}"
SOURCE_APP="${CCSWITCH_PATCHED_APP:-}"
OPEN_AFTER=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      SOURCE_APP="${2:-}"
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR="${2:-}"
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
  echo "CC Switch deployment is currently macOS-only." >&2
  exit 1
fi

candidate_sources=()
[[ -n "$SOURCE_APP" ]] && candidate_sources+=("$SOURCE_APP")
candidate_sources+=(
  "$HOME/.claude-science/cc-switch-src/src-tauri/target/release/bundle/macos/CC Switch.app"
  "/tmp/cc-switch-src/src-tauri/target/release/bundle/macos/CC Switch.app"
)

for candidate in "${candidate_sources[@]}"; do
  if [[ -d "$candidate" ]]; then
    SOURCE_APP="$candidate"
    break
  fi
done

tmp_dir=""
if [[ ! -d "$SOURCE_APP" ]]; then
  tmp_dir="$(mktemp -d)"
  zip_path="$tmp_dir/ccswitch.zip"
  echo "Downloading patched CC Switch from $ZIP_URL"
  curl -L --fail --silent --show-error "$ZIP_URL" -o "$zip_path"
  ditto -x -k "$zip_path" "$tmp_dir/unpacked"
  SOURCE_APP="$(find "$tmp_dir/unpacked" -maxdepth 3 -name 'CC Switch.app' -type d | head -1)"
fi

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Patched CC Switch.app was not found." >&2
  exit 1
fi

if ! grep -R -a -q "claude-science" "$SOURCE_APP" 2>/dev/null; then
  echo "Source app does not appear to contain the Claude Science patch: $SOURCE_APP" >&2
  exit 1
fi

if [[ -z "$INSTALL_DIR" ]]; then
  if [[ -d "/Applications/CC Switch.app" ]]; then
    INSTALL_DIR="/Applications"
  elif [[ -d "$HOME/Applications/CC Switch.app" ]]; then
    INSTALL_DIR="$HOME/Applications"
  else
    INSTALL_DIR="$HOME/Applications"
  fi
fi
mkdir -p "$INSTALL_DIR" "$BACKUP_ROOT"

DEST_APP="$INSTALL_DIR/CC Switch.app"
stamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="$BACKUP_ROOT/$stamp"
backup_app="$backup_dir/CC Switch.app"

echo "Stopping CC Switch if it is running..."
osascript -e 'tell application "CC Switch" to quit' >/dev/null 2>&1 || true
sleep 2

if [[ -d "$DEST_APP" ]]; then
  mkdir -p "$backup_dir"
  echo "Backing up existing app to $backup_app"
  ditto "$DEST_APP" "$backup_app"
  cat > "$backup_dir/metadata.json" <<EOF
{
  "created_at": "$stamp",
  "dest_app": "$DEST_APP",
  "source_app": "$SOURCE_APP"
}
EOF
fi

echo "Installing patched app to $DEST_APP"
rm -rf "$DEST_APP"
ditto "$SOURCE_APP" "$DEST_APP"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
codesign --force --deep --sign - "$DEST_APP" >/dev/null
codesign --verify --deep --strict --verbose=2 "$DEST_APP" >/dev/null

if [[ "$OPEN_AFTER" -eq 1 ]]; then
  echo "Opening patched CC Switch..."
  open "$DEST_APP"
fi

echo "Patched CC Switch deployed."
echo "Installed: $DEST_APP"
if [[ -d "$backup_app" ]]; then
  echo "Backup: $backup_app"
fi

if [[ -n "$tmp_dir" ]]; then
  rm -rf "$tmp_dir"
fi
