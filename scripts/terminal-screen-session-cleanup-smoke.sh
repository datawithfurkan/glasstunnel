#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp)"
PROCESS_FIXTURE="$(mktemp)"
NO_SESSION_CANDIDATE_FIXTURE="$(mktemp)"
OUTPUT="$(mktemp)"
PRUNE_OUTPUT="$(mktemp)"
trap 'rm -f "$FIXTURE" "$PROCESS_FIXTURE" "$NO_SESSION_CANDIDATE_FIXTURE" "$OUTPUT" "$PRUNE_OUTPUT"' EXIT

cat > "$FIXTURE" <<'FIXTURE_EOF'
There are screens on:
    62311.glasstunnel-terminal-1781597997067-089C045E (Attached)
    52191.glasstunnel-terminal-1781532428 (Detached)
    7271.glasstunnel-terminal (Detached)
    14627.glasstunnel-terminal-same-2 (Detached)
    70356.glasstunnel-terminal-two (Detached)
5 Sockets in /var/folders/test.
FIXTURE_EOF

cat > "$PROCESS_FIXTURE" <<'PROCESS_FIXTURE_EOF'
 1111     1 S    /usr/bin/screen -xRR -S glasstunnel-terminal
 1112     1 S    /usr/bin/screen -xRR -S glasstunnel-terminal-1781532428
 1113  2222 S    /usr/bin/screen -xRR -S glasstunnel-terminal-1781532428
 1114     1 Ss   /usr/bin/SCREEN -xRR -S glasstunnel-terminal
 1115     1 S    /usr/bin/screen -xRR -S manually-named-session
PROCESS_FIXTURE_EOF

cat > "$NO_SESSION_CANDIDATE_FIXTURE" <<'NO_SESSION_CANDIDATE_FIXTURE_EOF'
There are screens on:
    7271.glasstunnel-terminal (Detached)
1 Socket in /var/folders/test.
NO_SESSION_CANDIDATE_FIXTURE_EOF

GT_TERMINAL_SCREEN_LIST_FILE="$FIXTURE" \
GT_TERMINAL_SCREEN_PROCESS_FILE="$PROCESS_FIXTURE" \
  bash "$ROOT_DIR/scripts/terminal-screen-session-cleanup.sh" > "$OUTPUT"

grep -q "Sessions observed: 5" "$OUTPUT"
grep -q "Detached generated cleanup candidates: 1" "$OUTPUT"
grep -q "Orphan attach client candidates: 2" "$OUTPUT"
grep -q "52191.glasstunnel-terminal-1781532428" "$OUTPUT"
grep -q "1111.glasstunnel-terminal" "$OUTPUT"
grep -q "1112.glasstunnel-terminal-1781532428" "$OUTPUT"
if grep -q "62311.glasstunnel-terminal-1781597997067-089C045E" "$OUTPUT"; then
  echo "Result: failed; attached generated session was selected for cleanup." >&2
  exit 1
fi
if grep -q "1113.glasstunnel-terminal-1781532428" "$OUTPUT"; then
  echo "Result: failed; non-orphan screen client was selected for cleanup." >&2
  exit 1
fi
if grep -q "1114.glasstunnel-terminal" "$OUTPUT"; then
  echo "Result: failed; screen server process was selected for cleanup." >&2
  exit 1
fi
if grep -q "glasstunnel-terminal-same-2" "$OUTPUT"; then
  echo "Result: failed; manually named session was selected for cleanup." >&2
  exit 1
fi
if grep -q "7271.glasstunnel-terminal" "$OUTPUT"; then
  echo "Result: failed; shared default session was selected for cleanup." >&2
  exit 1
fi

GT_TERMINAL_SCREEN_LIST_FILE="$NO_SESSION_CANDIDATE_FIXTURE" \
GT_TERMINAL_SCREEN_PROCESS_FILE="$PROCESS_FIXTURE" \
GT_TERMINAL_SCREEN_CLEANUP_PRUNE=1 \
  bash "$ROOT_DIR/scripts/terminal-screen-session-cleanup.sh" > "$PRUNE_OUTPUT"

grep -q "Detached generated cleanup candidates: 0" "$PRUNE_OUTPUT"
grep -q "Orphan attach client candidates: 2" "$PRUNE_OUTPUT"
grep -q "Result: dry-run; pruning is disabled when fixture input is used." "$PRUNE_OUTPUT"

echo "Result: passed; Terminal screen-session cleanup classifier is conservative."
