#!/usr/bin/env bash
# Smoke-test the Homebrew cask updater without touching the tracked cask.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SOURCE_CASK="$ROOT_DIR/Casks/glasstunnel.rb"
TMP_CASK="$TMP_DIR/glasstunnel.rb"
TMP_DMG="$TMP_DIR/Glasstunnel-9.8.7.dmg"
DIRECT_SHA="ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789"
DIRECT_SHA_LOWER="$(printf '%s' "$DIRECT_SHA" | tr '[:upper:]' '[:lower:]')"

fail() {
  echo "Homebrew cask update smoke failed: $*" >&2
  exit 1
}

require_text() {
  local path="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" "$path"; then
    fail "${path#$TMP_DIR/} must contain: $needle"
  fi
}

reject_text() {
  local path="$1"
  local needle="$2"
  if grep -Fq -- "$needle" "$path"; then
    fail "${path#$TMP_DIR/} must not contain: $needle"
  fi
}

cp "$SOURCE_CASK" "$TMP_CASK"

GT_CASK_FILE="$TMP_CASK" \
  bash "$ROOT_DIR/scripts/update-homebrew-cask.sh" 9.8.7 "$DIRECT_SHA" \
  >/tmp/glasstunnel-cask-direct-sha-smoke.log

require_text "$TMP_CASK" 'version "9.8.7"'
require_text "$TMP_CASK" "sha256 \"$DIRECT_SHA_LOWER\""
require_text "$TMP_CASK" 'releases/download/v#{version}/Glasstunnel-#{version}.dmg'
require_text "$TMP_CASK" 'verified: "github.com/datawithfurkan/glasstunnel"'
reject_text "$TMP_CASK" "sha256 :no_check"

if GT_CASK_FILE="$TMP_CASK" \
  bash "$ROOT_DIR/scripts/update-homebrew-cask.sh" "bad version" "$DIRECT_SHA" \
  >/tmp/glasstunnel-cask-invalid-version-smoke.log 2>&1; then
  fail "expected invalid version to fail"
fi

cp "$SOURCE_CASK" "$TMP_CASK"
printf 'fake dmg bytes for cask smoke\n' > "$TMP_DMG"
DMG_SHA="$(shasum -a 256 "$TMP_DMG" | awk '{print $1}')"

GT_CASK_FILE="$TMP_CASK" \
  bash "$ROOT_DIR/scripts/update-homebrew-cask.sh" 9.8.7 "$TMP_DMG" \
  >/tmp/glasstunnel-cask-dmg-path-smoke.log

require_text "$TMP_CASK" 'version "9.8.7"'
require_text "$TMP_CASK" "sha256 \"$DMG_SHA\""
reject_text "$TMP_CASK" "sha256 :no_check"

if GT_CASK_FILE="$TMP_CASK" \
  bash "$ROOT_DIR/scripts/update-homebrew-cask.sh" 9.8.7 "$TMP_DIR/missing.dmg" \
  >/tmp/glasstunnel-cask-missing-dmg-smoke.log 2>&1; then
  fail "expected missing DMG path to fail"
fi

echo "Homebrew cask update smoke passed."
