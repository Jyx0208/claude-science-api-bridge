#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-$HOME/.claude-science/bin/claude-science}"
PROXY_PORT="${PROXY_PORT:-9876}"
PROXY_HTTPS_PORT="${PROXY_HTTPS_PORT:-9877}"
PYTHON_BIN="${PYTHON:-python3}"

if [ "${#PROXY_PORT}" -ne 4 ] || [ "${#PROXY_HTTPS_PORT}" -ne 4 ]; then
  echo "PROXY_PORT must be four digits for the byte-length-preserving daemon auth patch."
  echo "Current PROXY_PORT=$PROXY_PORT PROXY_HTTPS_PORT=$PROXY_HTTPS_PORT"
  exit 1
fi

if [ ! -f "$TARGET" ]; then
  echo "Claude Science daemon binary not found: $TARGET"
  echo "Open Claude Science once, then rerun this script."
  exit 1
fi

export TARGET PROXY_PORT PROXY_HTTPS_PORT

"$PYTHON_BIN" - <<'PY'
import os
import shutil
import stat
from pathlib import Path

target = Path(os.environ["TARGET"]).expanduser()
port = os.environ["PROXY_PORT"]
https_port = os.environ["PROXY_HTTPS_PORT"]
backup = target.with_name(target.name + ".byok-auth-original")

pairs = [
    (
        [b"https://claude.ai"],
        f"http://127.1:{port}".encode(),
    ),
    (
        [b"https://api.anthropic.com"],
        f"http://127.00.00.001:{port}".encode(),
    ),
    (
        [b"https://api.anthropic.com/api/oauth/profile"],
        f"http://127.00.00.001:{port}/api/oauth/profile".encode(),
    ),
    (
        [b"https://api.anthropic.com/api/oauth/account"],
        f"http://127.00.00.001:{port}/api/oauth/account".encode(),
    ),
    (
        [b"https://api.anthropic.com/api/oauth/usage"],
        f"http://127.00.00.001:{port}/api/oauth/usage".encode(),
    ),
    (
        [
            b"https://platform.claude.com/v1/oauth/token",
            f"http://127.000.000.01:{port}/api/oauth/token".encode(),
        ],
        f"https://127.00.00.001:{https_port}/api/oauth/token".encode(),
    ),
]

for olds, new in pairs:
    for old in olds:
        if len(old) != len(new):
            raise SystemExit(f"length mismatch: {old!r} ({len(old)}) -> {new!r} ({len(new)})")

data = target.read_bytes()
counts = [(olds, new, sum(data.count(old) for old in olds), data.count(new)) for olds, new in pairs]
missing = [
    " or ".join(old.decode() for old in olds)
    for olds, new, old_count, new_count in counts
    if old_count == 0 and new_count == 0
]
if missing:
    raise SystemExit(
        "Unsupported Claude Science daemon build; expected OAuth URL(s) not found:\n"
        + "\n".join(f"  - {item}" for item in missing)
    )

if any(old_count > 0 for _, _, old_count, _ in counts) and not backup.exists():
    shutil.copy2(target, backup)
    print(f"Backup written: {backup}")
elif backup.exists():
    print(f"Backup exists: {backup}")

patched = 0
with target.open("r+b") as f:
    for olds, new, old_count, new_count in counts:
        for old in olds:
            start = 0
            while True:
                idx = data.find(old, start)
                if idx < 0:
                    break
                f.seek(idx)
                f.write(new)
                patched += 1
                start = idx + len(old)

mode = target.stat().st_mode
target.chmod(mode | stat.S_IXUSR)

after = target.read_bytes()
for olds, new, _, _ in counts:
    for old in olds:
        if after.count(old) != 0:
            raise SystemExit(f"patch verification failed; original URL still present: {old.decode()}")
    if after.count(new) == 0:
        raise SystemExit(f"patch verification failed; replacement URL missing: {new.decode()}")

if patched:
    print(f"Patched {patched} OAuth URL occurrence(s) in {target}")
else:
    print(f"Already patched: {target}")
PY

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$TARGET" >/dev/null
  echo "Ad-hoc signed patched daemon binary."
else
  echo "Warning: codesign not found; patched daemon may not start on macOS."
fi

if ! "$TARGET" --help >/dev/null 2>&1; then
  echo "Patched daemon failed executable check; restoring backup." >&2
  if [ -f "$TARGET.byok-auth-original" ]; then
    cp "$TARGET.byok-auth-original" "$TARGET"
    chmod +x "$TARGET"
  fi
  exit 1
fi

echo "Patched daemon executable check passed."
