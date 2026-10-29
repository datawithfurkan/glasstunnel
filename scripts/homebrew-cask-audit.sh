#!/usr/bin/env bash
# Audit the tracked cask through a disposable local Homebrew tap.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_CASK="$ROOT_DIR/Casks/glasstunnel.rb"
TAP="glasstunnel/audit"
TOKEN="glasstunnel"
CASK_REF="$TAP/$TOKEN"
tap_created=0
developer_was_enabled=0
trust_supported=0
cask_was_trusted=0

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ENV_HINTS=1

# Current Homebrew refuses to load casks from untrusted taps. Trust only the
# disposable cask for this run and put its trust entry back the way it was.
cask_trusted() {
  local entries
  entries="$(brew trust --cask --json=v1 2>/dev/null)" || return 1
  grep -Fq "\"$CASK_REF\"" <<<"$entries"
}

restore_cask_trust() {
  if [[ "$trust_supported" != "1" ]]; then
    return
  fi
  if [[ "$cask_was_trusted" == "1" ]]; then
    brew trust --cask "$CASK_REF" >/dev/null 2>&1 ||
      echo "Warning: could not restore Homebrew trust for $CASK_REF." >&2
  elif ! brew untrust --cask "$CASK_REF" >/dev/null 2>&1 || cask_trusted; then
    echo "Warning: could not remove Homebrew trust for $CASK_REF; run \`brew untrust --cask $CASK_REF\`." >&2
  fi
}

cleanup() {
  if [[ "$tap_created" == "1" ]]; then
    restore_cask_trust
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
if brew trust --help >/dev/null 2>&1; then
  trust_supported=1
  if cask_trusted; then
    cask_was_trusted=1
  fi
fi

brew tap-new --no-git "$TAP" >/dev/null
tap_created=1
tap_root="$(brew --repository "$TAP")"
mkdir -p "$tap_root/Casks"
cp "$SOURCE_CASK" "$tap_root/Casks/$TOKEN.rb"
if [[ "$trust_supported" == "1" ]]; then
  brew trust --cask "$CASK_REF" >/dev/null
fi

brew audit --cask --strict "$CASK_REF"
echo "Tracked Homebrew cask audit passed."
