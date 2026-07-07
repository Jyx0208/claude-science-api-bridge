#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${CCSWITCH_SRC_DIR:-$HOME/.claude-science/cc-switch-src}"
REPO_URL="${CCSWITCH_REPO_URL:-https://github.com/farion1231/cc-switch.git}"
DO_BUILD=1
INSTALL_RUST=0
OPEN_OUTPUT=0
BUNDLES="app"

usage() {
  cat <<'EOF'
Build a CC Switch source tree with the Claude Science panel patch.

Usage:
  scripts/build-patched-ccswitch.sh [--src DIR] [--install-rust] [--no-build] [--dmg] [--open]

Options:
  --src DIR        CC Switch source directory. Default: ~/.claude-science/cc-switch-src
  --install-rust  Install Rust with rustup into ~/.cargo and ~/.rustup if cargo/rustc is missing.
  --no-build      Apply patch, install JS dependencies, and run TypeScript check only.
  --dmg           Also try to build a DMG. By default the script builds the .app bundle only.
  --open          Open the bundle output directory after a successful macOS build.

This script does not change Clash, VPN, TUN, DNS, system proxy, /etc/hosts,
certificate trust, or port 443.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src)
      SRC_DIR="${2:-}"
      shift 2
      ;;
    --install-rust)
      INSTALL_RUST=1
      shift
      ;;
    --no-build)
      DO_BUILD=0
      shift
      ;;
    --dmg)
      BUNDLES="app,dmg"
      shift
      ;;
    --open)
      OPEN_OUTPUT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$SRC_DIR" ]]; then
  echo "--src cannot be empty" >&2
  exit 2
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required." >&2
  exit 1
fi

if [[ ! -d "$SRC_DIR/.git" ]]; then
  mkdir -p "$(dirname "$SRC_DIR")"
  git clone "$REPO_URL" "$SRC_DIR"
fi

if [[ ! -f "$SRC_DIR/package.json" || ! -d "$SRC_DIR/src-tauri" ]]; then
  echo "Not a CC Switch source directory: $SRC_DIR" >&2
  exit 1
fi

patch_present() {
  if command -v rg >/dev/null 2>&1; then
    rg -q "ClaudeScience|claude-science" "$SRC_DIR/src-tauri/src" "$SRC_DIR/src" 2>/dev/null
  else
    grep -R -E -q "ClaudeScience|claude-science" "$SRC_DIR/src-tauri/src" "$SRC_DIR/src" 2>/dev/null
  fi
}

if patch_present; then
  echo "Claude Science patch already appears to be present: $SRC_DIR"
else
  "$ROOT_DIR/scripts/patch-ccswitch-source.sh" "$SRC_DIR"
fi

cd "$SRC_DIR"

if ! command -v pnpm >/dev/null 2>&1; then
  if command -v corepack >/dev/null 2>&1; then
    corepack enable pnpm >/dev/null 2>&1 || true
  fi
fi
if ! command -v pnpm >/dev/null 2>&1; then
  echo "pnpm is required. Ask the local agent to install Node.js/pnpm, then rerun this script." >&2
  exit 1
fi

if ! pnpm install --frozen-lockfile; then
  if [[ -x ./node_modules/.bin/tsc ]]; then
    echo "pnpm install returned a non-zero status, but node_modules exists; continuing to typecheck."
  else
    echo "pnpm install failed before TypeScript dependencies were available." >&2
    exit 1
  fi
fi

./node_modules/.bin/tsc --noEmit

if [[ "$DO_BUILD" -eq 0 ]]; then
  echo "Patch and TypeScript check completed. Build skipped by --no-build."
  exit 0
fi

if (! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1) && [[ -f "$HOME/.cargo/env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi

if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
  if [[ "$INSTALL_RUST" -ne 1 ]]; then
    echo "Rust/cargo is required for Tauri build." >&2
    echo "Rerun with --install-rust to let the agent install Rust into ~/.cargo and ~/.rustup." >&2
    exit 1
  fi
  tmp_script="$(mktemp)"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "$tmp_script"
  sh "$tmp_script" -y --profile minimal
  rm -f "$tmp_script"
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi

./node_modules/.bin/vite build
./node_modules/.bin/tauri build --ci --bundles "$BUNDLES" --config '{"build":{"beforeBuildCommand":""},"bundle":{"createUpdaterArtifacts":false}}'

bundle_dir="$SRC_DIR/src-tauri/target/release/bundle"
echo "CC Switch build output: $bundle_dir"
app_path="$bundle_dir/macos/CC Switch.app"
if [[ -d "$app_path" && "$(uname -s)" == "Darwin" ]]; then
  codesign --force --deep --sign - "$app_path"
  codesign --verify --deep --strict --verbose=2 "$app_path"
  zip_path="$bundle_dir/macos/CC-Switch-Claude-Science-aarch64.zip"
  rm -f "$zip_path"
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
  echo "Zipped app bundle: $zip_path"
fi
if [[ "$OPEN_OUTPUT" -eq 1 && "$(uname -s)" == "Darwin" ]]; then
  open "$bundle_dir"
fi
