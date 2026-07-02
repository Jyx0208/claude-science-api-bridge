#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-$HOME/.claude-science/bin/claude-science}"
BACKUP="$TARGET.byok-auth-original"

if [ ! -f "$BACKUP" ]; then
  echo "Backup not found: $BACKUP"
  exit 1
fi

cp "$BACKUP" "$TARGET"
chmod +x "$TARGET"
echo "Restored Claude Science daemon binary from: $BACKUP"

