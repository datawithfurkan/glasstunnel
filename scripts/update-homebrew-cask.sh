#!/usr/bin/env bash
# Update the local Homebrew cask recipe for a published Glasstunnel DMG.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASK_FILE="${GT_CASK_FILE:-$ROOT_DIR/Casks/glasstunnel.rb}"

usage() {
  cat <<'USAGE'
Usage: bash scripts/update-homebrew-cask.sh VERSION [DMG_PATH|SHA256]

Updates Casks/glasstunnel.rb with the release version and DMG sha256.

Arguments:
  VERSION            Release version, for example 0.1.0.
  DMG_PATH|SHA256    Optional. Defaults to dist/Glasstunnel-VERSION.dmg.
                     Pass a 64-character sha256 directly when the DMG is remote.

Examples:
  bash scripts/update-homebrew-cask.sh 0.1.0
  bash scripts/update-homebrew-cask.sh 0.1.0 dist/Glasstunnel-0.1.0.dmg
  bash scripts/update-homebrew-cask.sh 0.1.0 0123abcd...

Testing:
  GT_CASK_FILE=/tmp/glasstunnel.rb bash scripts/update-homebrew-cask.sh 0.1.0 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

VERSION="${1:-}"
SOURCE="${2:-}"

if [[ -z "$VERSION" ]]; then
  usage >&2
  exit 2
fi

if [[ ! "$VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+([.-][0-9A-Za-z]+)*$ ]]; then
  echo "Invalid version: $VERSION" >&2
  exit 2
fi

if [[ ! -f "$CASK_FILE" ]]; then
  echo "Cask file not found: $CASK_FILE" >&2
  exit 1
fi

if [[ -z "$SOURCE" ]]; then
  SOURCE="$ROOT_DIR/dist/Glasstunnel-$VERSION.dmg"
fi

if [[ "$SOURCE" =~ ^[0-9a-fA-F]{64}$ ]]; then
  SHA256="$(printf '%s' "$SOURCE" | tr '[:upper:]' '[:lower:]')"
else
  if [[ ! -f "$SOURCE" ]]; then
    echo "DMG not found: $SOURCE" >&2
    echo "Pass a local DMG path or a 64-character sha256." >&2
    exit 1
  fi
  SHA256="$(shasum -a 256 "$SOURCE" | awk '{print $1}')"
fi

perl -0pi -e 's/^(\s*)version "[^"]+"/${1}version "'"$VERSION"'"/m' "$CASK_FILE"
perl -0pi -e 's/^(\s*)sha256 .*$/${1}sha256 "'"$SHA256"'"/m' "$CASK_FILE"

echo "Updated $CASK_FILE"
echo "  version: $VERSION"
echo "  sha256: $SHA256"
echo
echo "Next release steps:"
echo "  1. Publish dist/Glasstunnel-$VERSION.dmg to GitHub Releases as v$VERSION."
echo "  2. Run: brew audit --cask --strict Casks/glasstunnel.rb"
echo "  3. Commit the cask update or copy it into the public Homebrew tap."
