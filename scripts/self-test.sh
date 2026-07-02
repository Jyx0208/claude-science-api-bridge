#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON="${PYTHON:-python3}"

"$PYTHON" -m py_compile \
  "$PROJECT_DIR/proxy.py" \
  "$PROJECT_DIR/setup-token.py" \
  "$PROJECT_DIR/forward-443.py"

for f in "$PROJECT_DIR"/*.sh "$PROJECT_DIR"/scripts/*.sh; do
  bash -n "$f"
done

"$PYTHON" - <<PY
import importlib.util
from pathlib import Path

path = Path("$PROJECT_DIR/tests/test_translation.py")
spec = importlib.util.spec_from_file_location("test_translation", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
tests = sorted(name for name in dir(mod) if name.startswith("test_"))
for name in tests:
    getattr(mod, name)()
    print(f"{name} passed")
print(f"{len(tests)} translation tests passed")
PY

echo "self-test passed"
