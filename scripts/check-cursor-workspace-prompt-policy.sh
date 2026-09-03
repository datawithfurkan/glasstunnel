#!/usr/bin/env bash
# Guard Cursor workspace-name /prompt routing from being overclaimed as
# existing-chat target switching.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$ROOT_DIR/docs/cursor-workspace-prompt-routing.md"
CURSOR_ADAPTER="$ROOT_DIR/apps/host-macos/Sources/Adapters/Cursor/CursorAdapter.swift"
AGENT_CARD="$ROOT_DIR/apps/mobile-pwa/src/agents/AgentCard.tsx"
SUPPORT_MATRIX="$ROOT_DIR/docs/agent-app-support-matrix.md"

fail() {
  echo "Cursor workspace prompt policy check failed: $*" >&2
  exit 1
}

[[ -f "$DOC" ]] || fail "missing $DOC"

grep -q "Defer shipping workspace-name \`/prompt\` routing" "$DOC" \
  || fail "policy doc must explicitly defer workspace-name /prompt routing"
grep -q "not prove that Glasstunnel can use it as existing-chat" "$DOC" \
  || fail "policy doc must separate /prompt from existing-chat switching"
grep -q "supportsNewThread" "$DOC" \
  || fail "policy doc must mention the new-thread advertisement boundary"
grep -q "Reconsideration Criteria" "$DOC" \
  || fail "policy doc must define when to revisit the decision"

grep -q "supportsNewThread: false" "$CURSOR_ADAPTER" \
  || fail "Cursor adapter must not advertise new-thread support"
grep -q "Open this chat" "$AGENT_CARD" \
  || fail "mobile Cursor target UI must keep the unverified-selection copy"
grep -q "Non-current chat routing" "$SUPPORT_MATRIX" \
  || fail "support matrix must retain the unverified non-current routing boundary"
grep -q "separate product path" "$DOC" \
  || fail "policy doc must keep workspace /prompt separate from existing-chat switching"

echo "Cursor workspace prompt policy is guarded."
