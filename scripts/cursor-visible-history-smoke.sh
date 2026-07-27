#!/usr/bin/env bash
# Privacy-safe visible Cursor history smoke.
#
# Compares the selected Cursor target history parsed by CursorStateWatcher with
# the real Cursor window exposed through macOS Accessibility. The tool prints
# counts only; it never prints Cursor target names, prompts, responses, raw
# message text, database paths, or raw JSON.
#
# Set GT_CURSOR_VISIBLE_HISTORY_ARTIFACT to write the same privacy-safe counts
# to a durable JSON artifact.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Result: blocked; Cursor visible history smoke requires macOS." >&2
  exit 1
fi

swift run --package-path "$ROOT_DIR/apps/host-macos" CursorVisibleHistoryTool
