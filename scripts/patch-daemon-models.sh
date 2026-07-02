#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${1:-$HOME/.claude-science/bin/claude-science}"
PYTHON_BIN="${PYTHON:-python3}"
STATE_FILE="${STATE_FILE:-$PROJECT_DIR/.daemon-model-patch.json}"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_DIR/config.json}"

if [ ! -f "$TARGET" ]; then
  echo "Claude Science daemon binary not found: $TARGET"
  echo "Open Claude Science once, then rerun this script."
  exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config file not found: $CONFIG_FILE"
  exit 1
fi

export TARGET PROJECT_DIR STATE_FILE CONFIG_FILE

"$PYTHON_BIN" - <<'PY'
import json
import os
import re
import shutil
import stat
from pathlib import Path

target = Path(os.environ["TARGET"]).expanduser()
project_dir = Path(os.environ["PROJECT_DIR"]).expanduser()
config_file = Path(os.environ["CONFIG_FILE"]).expanduser()
state_file = Path(os.environ["STATE_FILE"]).expanduser()

slots = [
    {
        "slot": 1,
        "original_id": "claude-opus-4-8",
        "original_name": "Claude Opus 4.8",
        "alias_id": "byok-model-0001",
        "default_name": "Kimi K2.6 Pro++",
    },
    {
        "slot": 2,
        "original_id": "claude-sonnet-5",
        "original_name": "Claude Sonnet 5",
        "alias_id": "byok-model-0002",
        "default_name": "BYOK Model 0002",
    },
    {
        "slot": 3,
        "original_id": "claude-sonnet-4-6",
        "original_name": "Claude Sonnet 4.6",
        "alias_id": "byok-model-000003",
        "default_name": "BYOK Model 000003",
    },
]


def load_json(path, fallback):
    try:
        return json.loads(path.read_text())
    except Exception:
        return fallback


def ascii_clean(value):
    text = str(value or "")
    text = text.replace("–", "-").replace("—", "-")
    text = re.sub(r"[^\x20-\x7e]", "", text)
    return re.sub(r"\s+", " ", text).strip()


def fit_bytes(value, size, fallback):
    text = ascii_clean(value) or fallback
    raw = text.encode("ascii", "ignore")
    if len(raw) > size:
        raw = raw[:size]
        text = raw.decode("ascii", "ignore")
    if len(raw) < size:
        text = text + (" " * (size - len(raw)))
    if len(text.encode("ascii")) != size:
        raise SystemExit(f"cannot fit model label to {size} bytes: {value!r}")
    return text


def friendly_name(model):
    model = ascii_clean(model)
    lower = model.lower()
    if "kimi-k2.6" in lower or "kimi-k2" in lower:
        return "Kimi K2.6 Pro++"
    if "/" in model:
        return model.rsplit("/", 1)[-1]
    return model or "BYOK Model"


def normalize_aliases(raw):
    if isinstance(raw, dict):
        items = []
        for alias_id, value in raw.items():
            if isinstance(value, dict):
                item = dict(value)
                item.setdefault("id", alias_id)
            else:
                item = {"id": alias_id, "model": value}
            items.append(item)
    elif isinstance(raw, list):
        items = raw
    else:
        items = []
    out = []
    for item in items:
        if not isinstance(item, dict):
            continue
        alias_id = ascii_clean(item.get("id"))
        if not alias_id:
            continue
        backend = ascii_clean(item.get("backend")).lower()
        if backend not in {"", "deepseek", "openai", "custom"}:
            backend = ""
        model = ascii_clean(item.get("model")) or alias_id
        display_name = ascii_clean(item.get("display_name") or item.get("name")) or friendly_name(model)
        out.append({
            "id": alias_id,
            "backend": backend,
            "model": model,
            "display_name": display_name,
        })
    return out


config = load_json(config_file, {})
state = load_json(state_file, {})
old_slots = state.get("slots", []) if isinstance(state, dict) else []
old_by_slot = {
    int(item.get("slot")): item
    for item in old_slots
    if isinstance(item, dict) and str(item.get("slot", "")).isdigit()
}

configured = normalize_aliases(config.get("model_aliases"))
default_backend = ascii_clean(config.get("default_backend")).lower() or "custom"
if default_backend not in {"deepseek", "openai", "custom"}:
    default_backend = "custom"
default_model = ascii_clean(config.get("force_model"))
if not default_model:
    for key in ("custom_model_map", "deepseek_model_map", "openai_model_map"):
        model_map = config.get(key)
        if isinstance(model_map, dict) and model_map:
            default_model = ascii_clean(next(iter(model_map.values())))
            break
default_model = default_model or "Pro/moonshotai/Kimi-K2.6"

seed = configured[0] if configured else {
    "backend": default_backend,
    "model": default_model,
    "display_name": friendly_name(default_model),
}

aliases = []
for idx, slot in enumerate(slots):
    source = configured[idx] if idx < len(configured) else seed
    aliases.append({
        "id": slot["alias_id"],
        "backend": source.get("backend") or default_backend,
        "model": source.get("model") or default_model,
        "display_name": source.get("display_name") or slot["default_name"],
    })

changed_config = False
if config.get("model_aliases") != aliases:
    config["model_aliases"] = aliases
    changed_config = True
if config.get("model_list_mode") != "aliases":
    config["model_list_mode"] = "aliases"
    changed_config = True
if changed_config:
    config_file.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n")
    config_file.chmod(0o600)
    print(f"Updated model aliases in {config_file}")

backup = target.with_name(target.name + ".byok-model-original")
data = target.read_bytes()
if not backup.exists():
    shutil.copy2(target, backup)
    print(f"Backup written: {backup}")
else:
    print(f"Backup exists: {backup}")

patches = []
state_slots = []
for alias, slot in zip(aliases, slots):
    id_len = len(slot["original_id"].encode("ascii"))
    name_len = len(slot["original_name"].encode("ascii"))
    new_id = fit_bytes(alias["id"], id_len, slot["alias_id"])
    new_name = fit_bytes(alias["display_name"], name_len, slot["default_name"])
    previous = old_by_slot.get(slot["slot"], {})

    id_candidates = [
        slot["original_id"],
        previous.get("patched_id", ""),
        new_id,
    ]
    name_candidates = [
        slot["original_name"],
        previous.get("patched_name", ""),
        new_name,
    ]
    id_candidates = list(dict.fromkeys(c for c in id_candidates if c and len(c.encode("ascii")) == id_len))
    name_candidates = list(dict.fromkeys(c for c in name_candidates if c and len(c.encode("ascii")) == name_len))

    patches.append((slot["slot"], "id", id_candidates, new_id))
    patches.append((slot["slot"], "name", name_candidates, new_name))
    state_slots.append({
        "slot": slot["slot"],
        "id": alias["id"],
        "model": alias["model"],
        "backend": alias["backend"],
        "display_name": alias["display_name"],
        "patched_id": new_id,
        "patched_name": new_name,
    })

missing = []
for slot_no, kind, candidates, new_value in patches:
    if not any(data.count(candidate.encode("ascii")) for candidate in candidates):
        missing.append(f"slot {slot_no} {kind}: {' / '.join(candidates)}")
if missing:
    raise SystemExit(
        "Unsupported Claude Science daemon build; expected model string(s) not found:\n"
        + "\n".join(f"  - {item}" for item in missing)
    )

patched = 0
with target.open("r+b") as f:
    for _slot_no, _kind, candidates, new_value in patches:
        new_bytes = new_value.encode("ascii")
        for candidate in candidates:
            old_bytes = candidate.encode("ascii")
            if old_bytes == new_bytes:
                continue
            start = 0
            while True:
                idx = data.find(old_bytes, start)
                if idx < 0:
                    break
                f.seek(idx)
                f.write(new_bytes)
                data = data[:idx] + new_bytes + data[idx + len(old_bytes):]
                patched += 1
                start = idx + len(new_bytes)

mode = target.stat().st_mode
target.chmod(mode | stat.S_IXUSR)

after = target.read_bytes()
for slot_state, slot in zip(state_slots, slots):
    if after.count(slot_state["patched_id"].encode("ascii")) == 0:
        raise SystemExit(f"patch verification failed; alias id missing: {slot_state['patched_id']}")
    if after.count(slot_state["patched_name"].encode("ascii")) == 0:
        raise SystemExit(f"patch verification failed; alias label missing: {slot_state['patched_name']}")

state_file.write_text(json.dumps({
    "target": str(target),
    "slots": state_slots,
}, indent=2, ensure_ascii=False) + "\n")

if patched:
    print(f"Patched {patched} model string occurrence(s) in {target}")
else:
    print(f"Already patched: {target}")
print("Claude-facing model aliases:")
for item in state_slots:
    print(f"  - {item['id']} -> {item['backend']}:{item['model']} ({item['display_name']})")
PY

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$TARGET" >/dev/null
  echo "Ad-hoc signed patched daemon binary."
else
  echo "Warning: codesign not found; patched daemon may not start on macOS."
fi

if ! "$TARGET" --help >/dev/null 2>&1; then
  echo "Patched daemon failed executable check; restoring model backup." >&2
  if [ -f "$TARGET.byok-model-original" ]; then
    cp "$TARGET.byok-model-original" "$TARGET"
    chmod +x "$TARGET"
  fi
  exit 1
fi

echo "Patched daemon model menu check passed."
