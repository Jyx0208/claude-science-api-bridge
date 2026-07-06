#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_FILE="$ROOT_DIR/patches/cc-switch-claude-science.patch"
DEFAULT_SRC="${CCSWITCH_SRC_DIR:-$HOME/.claude-science/cc-switch-src}"
SRC_DIR="${1:-$DEFAULT_SRC}"

if [[ ! -f "$PATCH_FILE" ]]; then
  echo "Patch file not found: $PATCH_FILE" >&2
  exit 1
fi

if [[ ! -d "$SRC_DIR/.git" ]]; then
  mkdir -p "$(dirname "$SRC_DIR")"
  git clone https://github.com/farion1231/cc-switch.git "$SRC_DIR"
fi

cd "$SRC_DIR"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "CC Switch source tree has local changes: $SRC_DIR" >&2
  echo "Commit/stash them or use a fresh source directory, then rerun." >&2
  exit 1
fi

if git apply --check "$PATCH_FILE"; then
  git apply "$PATCH_FILE"
  echo "Claude Science patch applied to: $SRC_DIR"
else
  echo "Patch cannot be applied cleanly. Check CC Switch version or use a fresh checkout." >&2
  exit 1
fi

cat <<'EOF'

Next agent steps:
1. Install CC Switch build dependencies if missing: Node.js/pnpm and Rust/cargo.
2. Run frontend typecheck, for example: ./node_modules/.bin/tsc --noEmit.
3. Build CC Switch with its normal Tauri build command.
4. Do not touch Clash, system proxy, /etc/hosts, certificates, or port 443.
EOF
