#!/usr/bin/env bash
# Packages an app bundle into the Glasstunnel installer DMG: a 660x400 window
# with the drag-to-Applications artwork, the app and an Applications link
# placed on it, and the app icon as the disk icon.
#
# Usage: bash scripts/dmg/build-dmg.sh path/to/Glasstunnel.app path/to/out.dmg
#
# Finder layout is written by dmgbuild (pinned below) into the image's
# .DS_Store, so no Finder scripting or Automation permission is involved.
# The tool is installed once into apps/host-macos/.build/dmg-tools.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ART_DIR="$ROOT_DIR/apps/host-macos/Metadata/dmg"
ICON="$ROOT_DIR/apps/host-macos/Metadata/AppIcon.icns"
TOOLS="$ROOT_DIR/apps/host-macos/.build/dmg-tools"
DMGBUILD_VERSION="1.6.5"

APP="${1:-}"
OUT="${2:-}"
if [[ -z "$APP" || -z "$OUT" || ! -d "$APP" ]]; then
  echo "Usage: bash scripts/dmg/build-dmg.sh path/to/Glasstunnel.app path/to/out.dmg" >&2
  exit 2
fi

if ! "$TOOLS/bin/python" -c "import dmgbuild, importlib.metadata as m; assert m.version('dmgbuild') == '$DMGBUILD_VERSION'" 2>/dev/null; then
  echo "==> Installing dmgbuild $DMGBUILD_VERSION into $TOOLS"
  python3 -m venv "$TOOLS"
  "$TOOLS/bin/pip" install --quiet --disable-pip-version-check "dmgbuild==$DMGBUILD_VERSION"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/glasstunnel-dmg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# One TIFF with both pixel densities, so the window is sharp on Retina displays.
tiffutil -cathidpicheck "$ART_DIR/background.png" "$ART_DIR/background@2x.png" \
  -out "$WORK/background.tiff" >/dev/null

rm -f "$OUT"
"$TOOLS/bin/dmgbuild" \
  -s "$ROOT_DIR/scripts/dmg/settings.py" \
  -D app="$APP" \
  -D background="$WORK/background.tiff" \
  -D icon="$ICON" \
  "Glasstunnel" "$OUT"
