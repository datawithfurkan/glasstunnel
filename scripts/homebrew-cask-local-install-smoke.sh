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
CASK_REF="$TAP/$TOKEN"
TMP_DIR="$(mktemp -d)"
INSTALL_DIR="$TMP_DIR/Applications"
CASK_FILE="$TMP_DIR/$TOKEN.rb"
INSTALLED_APP="$INSTALL_DIR/Glasstunnel.app"
EXPECTED_BUNDLE_ID="io.glasstunnel.host"
tap_created=0
developer_was_enabled=0
trust_supported=0
cask_was_trusted=0

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ENV_HINTS=1

# Current Homebrew refuses to load casks from untrusted taps, and `brew install`
# records trust for the casks it installs. Trust only the disposable cask for
# this run and put its trust entry back the way it was.
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
    brew uninstall --cask --force "$TOKEN" >/dev/null 2>&1 || true
    restore_cask_trust
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
the cask, restores the cask's Homebrew trust entry, and removes the temporary
directory. It does not publish a release, change Casks/glasstunnel.rb, or
install into /Applications.

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
if brew trust --help >/dev/null 2>&1; then
  trust_supported=1
  if cask_trusted; then
    cask_was_trusted=1
  fi
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
if [[ "$trust_supported" == "1" ]]; then
  brew trust --cask "$CASK_REF" >/dev/null
fi

echo "Glasstunnel local Homebrew cask install smoke"
echo "DMG: $DMG_PATH"
echo "Temporary app directory: $INSTALL_DIR"

brew install --cask \
  --appdir="$INSTALL_DIR" \
  "$CASK_REF"

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
