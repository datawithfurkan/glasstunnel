#!/usr/bin/env bash
# Audit the tracked cask through a disposable local Homebrew tap.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_CASK="$ROOT_DIR/Casks/glasstunnel.rb"
TAP="glasstunnel/audit"
TOKEN="glasstunnel"
tap_created=0
developer_was_enabled=0

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ENV_HINTS=1

cleanup() {
  if [[ "$tap_created" == "1" ]]; then
    brew untap --force "$TAP" >/dev/null 2>&1 || true
  fi
  if [[ "$developer_was_enabled" != "1" ]]; then
    brew developer off >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required for the cask audit." >&2
  exit 1
fi
if [[ ! -f "$SOURCE_CASK" ]]; then
  echo "Tracked cask not found: $SOURCE_CASK" >&2
  exit 1
fi
if brew developer state 2>/dev/null | grep -Fq "Developer mode is enabled"; then
  developer_was_enabled=1
fi
if brew tap | grep -Fxq "$TAP"; then
  echo "Refusing to reuse existing Homebrew tap $TAP." >&2
  exit 1
fi

brew tap-new --no-git "$TAP" >/dev/null
tap_created=1
tap_root="$(brew --repository "$TAP")"
mkdir -p "$tap_root/Casks"
cp "$SOURCE_CASK" "$tap_root/Casks/$TOKEN.rb"

brew audit --cask --strict "$TAP/$TOKEN"
echo "Tracked Homebrew cask audit passed."
