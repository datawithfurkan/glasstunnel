#!/usr/bin/env bash
# Keep the public site pointed at the stable latest-release DMG asset.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_DMG_URL="https://github.com/datawithfurkan/glasstunnel/releases/latest/download/Glasstunnel.dmg"
SITE_DIR="$ROOT_DIR/site"
FAILURES=0

shopt -s nullglob
HTML_FILES=("$SITE_DIR"/*.html)
shopt -u nullglob

if [[ "${#HTML_FILES[@]}" -eq 0 ]]; then
  echo "No site HTML files found under $SITE_DIR." >&2
  exit 1
fi

DMG_URLS_FILE="$(mktemp "${TMPDIR:-/tmp}/glasstunnel-site-dmg-urls.XXXXXX")"
MATCHES_FILE="$(mktemp "${TMPDIR:-/tmp}/glasstunnel-site-download-audit.XXXXXX")"
cleanup() {
  rm -f "$DMG_URLS_FILE" "$MATCHES_FILE"
}
trap cleanup EXIT

grep -Eho 'https://github[.]com/datawithfurkan/glasstunnel/releases/[^"'\'' <>)]+[.]dmg' "${HTML_FILES[@]}" >"$DMG_URLS_FILE" 2>/dev/null || true

if [[ ! -s "$DMG_URLS_FILE" ]]; then
  echo "No public DMG download link found in site HTML." >&2
  exit 1
fi

while IFS= read -r url; do
  if [[ "$url" != "$EXPECTED_DMG_URL" ]]; then
    echo "Unexpected site DMG URL: $url" >&2
    echo "Expected: $EXPECTED_DMG_URL" >&2
    FAILURES=$((FAILURES + 1))
  fi
done <"$DMG_URLS_FILE"

if grep -RInE 'releases/download/v[0-9][^"'\'' <>)]+/Glasstunnel-[0-9][^"'\'' <>)]+[.]dmg' "${HTML_FILES[@]}" >"$MATCHES_FILE" 2>/dev/null; then
  echo "Versioned DMG links must not be hardcoded in the public site:" >&2
  cat "$MATCHES_FILE" >&2
  FAILURES=$((FAILURES + 1))
fi

if [[ "$FAILURES" -ne 0 ]]; then
  exit 1
fi

echo "Site DMG links point at the stable latest-release asset."
