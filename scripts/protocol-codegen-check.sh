#!/usr/bin/env bash
# Regenerate protocol bindings and fail only if codegen changes the protocol diff.
#
# This works during active development where unrelated files may already be dirty.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BEFORE="$(mktemp -t glasstunnel-proto-before)"
AFTER="$(mktemp -t glasstunnel-proto-after)"
cleanup() {
  rm -f "$BEFORE" "$AFTER"
}
trap cleanup EXIT

git diff --no-ext-diff -- packages/protocol/schema apps/signaling/internal/proto packages/protocol/gen > "$BEFORE"
bash packages/protocol/scripts/gen.sh
git diff --no-ext-diff -- packages/protocol/schema apps/signaling/internal/proto packages/protocol/gen > "$AFTER"

if ! cmp -s "$BEFORE" "$AFTER"; then
  echo "Protocol generated files or schema changed after codegen." >&2
  echo "Run packages/protocol/scripts/gen.sh and inspect the protocol diff." >&2
  diff -u "$BEFORE" "$AFTER" || true
  exit 1
fi

echo "Protocol codegen check passed."
