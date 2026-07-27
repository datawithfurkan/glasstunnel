#!/usr/bin/env bash
# Privacy-safe live Cursor snapshot through the same CursorStateWatcher path used
# by the Mac app. This prints counts and shape metadata only; it never prints
# Cursor target names, prompts, responses, database paths, or raw JSON.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Result: blocked; Cursor live state snapshot requires macOS." >&2
  exit 1
fi

swift run --package-path "$ROOT_DIR/apps/host-macos" CursorStateSnapshotTool
