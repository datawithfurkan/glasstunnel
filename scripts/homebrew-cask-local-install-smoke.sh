#!/usr/bin/env bash
# Install a local Glasstunnel DMG through a disposable Homebrew cask.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == "--" ]]; then
  shift
fi

DMG_PATH="${1:-${GT_MAC_CASK_INSTALL_DMG:-}}"
TOKEN="glasstunnel-local-smoke"
TAP="glasstunnel/local-smoke"
TMP_DIR="$(mktemp -d)"
INSTALL_DIR="$TMP_DIR/Applications"
CASK_FILE="$TMP_DIR/$TOKEN.rb"
INSTALLED_APP="$INSTALL_DIR/Glasstunnel.app"
EXPECTED_BUNDLE_ID="io.glasstunnel.host"
tap_created=0
developer_was_enabled=0

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ENV_HINTS=1

cleanup() {
  if [[ "$tap_created" == "1" ]]; then
    brew uninstall --cask --force "$TOKEN" >/dev/null 2>&1 || true
    brew untap --force "$TAP" >/dev/null 2>&1 || true
  fi
  if [[ "$developer_was_enabled" != "1" ]]; then
    brew developer off >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage: bash scripts/homebrew-cask-local-install-smoke.sh [DMG_PATH]

Creates a disposable local-file Homebrew cask, installs Glasstunnel.app into a
temporary Applications directory, verifies the installed app, then uninstalls
the cask and removes the temporary directory. It does not publish a release,
change Casks/glasstunnel.rb, or install into /Applications.

Environment:
  GT_MAC_CASK_INSTALL_DMG  DMG path when no argument is supplied.
USAGE
}

if [[ "$DMG_PATH" == "-h" || "$DMG_PATH" == "--help" ]]; then
  usage
  exit 0
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required for the local cask install smoke." >&2
  exit 1
fi

if [[ -z "$DMG_PATH" ]]; then
  shopt -s nullglob
  dmgs=("$ROOT_DIR"/dist/Glasstunnel-*.dmg)
  shopt -u nullglob
  if [[ "${#dmgs[@]}" -eq 0 ]]; then
    echo "No Glasstunnel DMG found in dist/." >&2
    exit 1
  fi
  DMG_PATH="${dmgs[0]}"
  for dmg in "${dmgs[@]}"; do
    if [[ "$dmg" -nt "$DMG_PATH" ]]; then
      DMG_PATH="$dmg"
    fi
  done
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi
if brew developer state 2>/dev/null | grep -Fq "Developer mode is enabled"; then
  developer_was_enabled=1
fi

DMG_PATH="$(cd "$(dirname "$DMG_PATH")" && pwd)/$(basename "$DMG_PATH")"
version="$(basename "$DMG_PATH" .dmg)"
version="${version#Glasstunnel-}"
sha256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"

if brew list --cask --versions "$TOKEN" >/dev/null 2>&1; then
  echo "Refusing to reuse an existing $TOKEN cask receipt." >&2
  exit 1
fi
if brew tap | grep -Fxq "$TAP"; then
  echo "Refusing to reuse existing Homebrew tap $TAP." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
cat >"$CASK_FILE" <<CASK
cask "$TOKEN" do
  version "$version"
  sha256 "$sha256"
  url "file://$DMG_PATH"
  name "Glasstunnel Local Smoke"
  desc "Disposable local installation verification"
  homepage "https://glasstunnel.io/"
  app "Glasstunnel.app"
end
CASK

brew tap-new --no-git "$TAP" >/dev/null
tap_created=1
tap_root="$(brew --repository "$TAP")"
mkdir -p "$tap_root/Casks"
cp "$CASK_FILE" "$tap_root/Casks/$TOKEN.rb"

echo "Glasstunnel local Homebrew cask install smoke"
echo "DMG: $DMG_PATH"
echo "Temporary app directory: $INSTALL_DIR"

brew install --cask \
  --appdir="$INSTALL_DIR" \
  "$TAP/$TOKEN"

if [[ ! -d "$INSTALLED_APP" ]]; then
  echo "Homebrew did not install Glasstunnel.app into the temporary app directory." >&2
  exit 1
fi

bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
  "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
  echo "Expected bundle ID $EXPECTED_BUNDLE_ID, found '${bundle_id:-missing}'." >&2
  exit 1
fi

codesign --verify --deep --strict "$INSTALLED_APP"

echo "Local Homebrew cask install passed for Glasstunnel $version."
echo "The disposable cask receipt and temporary app are removed on exit."
