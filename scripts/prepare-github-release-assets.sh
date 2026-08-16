#!/usr/bin/env bash
# Prepare immutable and stable GitHub Release assets for a Mac DMG.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
DMG_PATH="${2:-}"
DIST_DIR="$ROOT_DIR/dist"

usage() {
  cat <<'USAGE'
Usage: bash scripts/prepare-github-release-assets.sh VERSION [DMG_PATH]

Creates checksum files for the versioned DMG and a stable latest-download alias:

  dist/Glasstunnel-VERSION.dmg
  dist/Glasstunnel-VERSION.dmg.sha256
  dist/Glasstunnel.dmg
  dist/Glasstunnel.dmg.sha256

Upload all four files to the GitHub Release. The website links to:

  https://github.com/datawithfurkan/glasstunnel/releases/latest/download/Glasstunnel.dmg

Homebrew continues to use the immutable versioned DMG URL and SHA-256.
USAGE
}

if [[ "$VERSION" == "-h" || "$VERSION" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$VERSION" == "--" ]]; then
  shift
  VERSION="${1:-}"
  DMG_PATH="${2:-}"
fi

if [[ -z "$VERSION" ]]; then
  usage >&2
  exit 2
fi

if [[ ! "$VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+([.-][0-9A-Za-z]+)*$ ]]; then
  echo "Invalid version: $VERSION" >&2
  exit 2
fi

if [[ -z "$DMG_PATH" ]]; then
  DMG_PATH="$DIST_DIR/Glasstunnel-$VERSION.dmg"
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

mkdir -p "$DIST_DIR"

VERSIONED_DMG="$DIST_DIR/Glasstunnel-$VERSION.dmg"
if [[ "$(cd "$(dirname "$DMG_PATH")" && pwd)/$(basename "$DMG_PATH")" != "$VERSIONED_DMG" ]]; then
  cp "$DMG_PATH" "$VERSIONED_DMG"
fi

LATEST_DMG="$DIST_DIR/Glasstunnel.dmg"
cp "$VERSIONED_DMG" "$LATEST_DMG"

versioned_sha="$(shasum -a 256 "$VERSIONED_DMG" | awk '{print $1}')"
latest_sha="$(shasum -a 256 "$LATEST_DMG" | awk '{print $1}')"

printf '%s  %s\n' "$versioned_sha" "$(basename "$VERSIONED_DMG")" >"$VERSIONED_DMG.sha256"
printf '%s  %s\n' "$latest_sha" "$(basename "$LATEST_DMG")" >"$LATEST_DMG.sha256"

echo "Prepared GitHub Release assets:"
echo "  $VERSIONED_DMG"
echo "  $VERSIONED_DMG.sha256"
echo "  $LATEST_DMG"
echo "  $LATEST_DMG.sha256"
echo
echo "SHA-256: $versioned_sha"
echo
echo "Upload command:"
echo "  gh release upload v$VERSION \\"
echo "    $VERSIONED_DMG $VERSIONED_DMG.sha256 \\"
echo "    $LATEST_DMG $LATEST_DMG.sha256"
