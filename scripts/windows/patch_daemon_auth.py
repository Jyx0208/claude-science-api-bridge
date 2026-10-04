#!/usr/bin/env python3
"""Windows port of scripts/patch-daemon-auth.sh.

Byte-length-preserving OAuth/profile URL patch for the Claude Science
Windows executable. Only the user-installed copy under
%LOCALAPPDATA%\\Programs\\ClaudeScience is touched; a backup is written
next to it before the first patch.

Usage:
    python patch_daemon_auth.py [--target PATH] [--port 9876] [--https-port 9877]
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

DEFAULT_INSTALL_DIRS = [
    Path.home() / "AppData" / "Local" / "Programs" / "ClaudeScience",
]


def detect_target() -> Path:
    """Locate claude-science.exe via install.json, then known paths."""
    for base in DEFAULT_INSTALL_DIRS:
        manifest = base / "install.json"
        if manifest.is_file():
            try:
                info = json.loads(manifest.read_text(encoding="utf-8"))
            except Exception:
                info = {}
            install_dir = str(info.get("install_dir") or "").strip()
            if install_dir:
                candidate = Path(install_dir) / "claude-science.exe"
                if candidate.is_file():
                    return candidate
        candidate = base / "claude-science.exe"
        if candidate.is_file():
            return candidate
    return None


def build_pairs(port: str, https_port: str):
    """Same replacement pairs as the macOS/Linux patch script."""
    return [
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


def check_locked(target: Path) -> bool:
    """Return True when the file is locked by a running process."""
    try:
        with target.open("r+b"):
            return False
    except PermissionError:
        return True


def verify_executable(target: Path) -> bool:
    """Run the console shim's --version as a smoke check after patching."""
    shim = target.with_name("claude-science.com")
    probe = shim if shim.is_file() else target
    try:
        result = subprocess.run(
            [str(probe), "--version"],
            capture_output=True,
            text=True,
            timeout=60,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        return result.returncode == 0
    except Exception:
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", default="", help="Path to claude-science.exe")
    parser.add_argument("--port", default=os.environ.get("PROXY_PORT", "9876"))
    parser.add_argument("--https-port", default=os.environ.get("PROXY_HTTPS_PORT", "9877"))
    args = parser.parse_args()

    port = str(args.port)
    https_port = str(args.https_port)
    if len(port) != 4 or len(https_port) != 4:
        print("PROXY_PORT must be four digits for the byte-length-preserving daemon auth patch.")
        print(f"Current port={port} https_port={https_port}")
        return 1

    target = Path(args.target).expanduser() if args.target else detect_target()
    if not target or not target.is_file():
        print("Claude Science executable not found.")
        print("Install Claude Science, or pass --target <path to claude-science.exe>.")
        return 1

    if check_locked(target):
        print(f"File is locked (Claude Science is probably running): {target}")
        print("Close Claude Science (or run scripts/windows/start-claude-science.ps1) and retry.")
        return 1

    pairs = build_pairs(port, https_port)
    for olds, new in pairs:
        for old in olds:
            if len(old) != len(new):
                print(f"length mismatch: {old!r} ({len(old)}) -> {new!r} ({len(new)})")
                return 1

    backup = target.with_name(target.name + ".byok-auth-original")
    try:
        data = target.read_bytes()
    except PermissionError:
        print(f"Cannot read (Claude Science is probably running): {target}")
        return 1

    counts = [(olds, new, sum(data.count(old) for old in olds), data.count(new)) for olds, new in pairs]
    missing = [
        " or ".join(old.decode() for old in olds)
        for olds, new, old_count, new_count in counts
        if old_count == 0 and new_count == 0
    ]
    if missing:
        print("Unsupported Claude Science build; expected OAuth URL(s) not found:")
        for item in missing:
            print(f"  - {item}")
        return 1

    if any(old_count > 0 for _, _, old_count, _ in counts) and not backup.exists():
        shutil.copy2(target, backup)
        print(f"Backup written: {backup}")
    elif backup.exists():
        print(f"Backup exists: {backup}")

    patched = 0
    try:
        with target.open("r+b") as f:
            for olds, new, _old_count, _new_count in counts:
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
    except PermissionError:
        print(f"Cannot write (Claude Science is probably running): {target}")
        return 1

    after = target.read_bytes()
    for olds, new, _, _ in counts:
        for old in olds:
            if after.count(old) != 0:
                print(f"patch verification failed; original URL still present: {old.decode()}")
                return 1
        if after.count(new) == 0:
            print(f"patch verification failed; replacement URL missing: {new.decode()}")
            return 1

    if patched:
        print(f"Patched {patched} OAuth URL occurrence(s) in {target}")
    else:
        print(f"Already patched: {target}")

    if not verify_executable(target):
        print("Patched executable failed the --version smoke check; restoring backup.")
        if backup.exists():
            shutil.copy2(backup, target)
        return 1
    print("Patched executable smoke check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
