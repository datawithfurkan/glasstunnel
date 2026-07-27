#!/usr/bin/env bash
set -euo pipefail

SCREEN_BIN="${GT_TERMINAL_SCREEN_BIN:-/usr/bin/screen}"
LIST_FILE="${GT_TERMINAL_SCREEN_LIST_FILE:-}"
PROCESS_FILE="${GT_TERMINAL_SCREEN_PROCESS_FILE:-}"
PRUNE="${GT_TERMINAL_SCREEN_CLEANUP_PRUNE:-0}"

if [[ -n "$LIST_FILE" ]]; then
  SCREEN_LIST="$(cat "$LIST_FILE")"
elif [[ ! -x "$SCREEN_BIN" ]]; then
  echo "Result: skipped; screen executable is unavailable at $SCREEN_BIN."
  exit 0
else
  SCREEN_LIST="$("$SCREEN_BIN" -ls || true)"
fi

session_count=0
candidate_count=0
orphan_client_count=0
declare -a candidates=()
declare -a orphan_clients=()
screen_line_re='^[[:space:]]*([0-9]+)\.([^[:space:]\(]+)[[:space:]]+\(([^)]*)\)'
process_line_re='^[[:space:]]*([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+[^[:space:]]+[[:space:]]+(.+)$'
attach_session_re='(^|[[:space:]])-S[[:space:]]+([^[:space:]]+)'

while IFS= read -r line; do
  if [[ "$line" =~ $screen_line_re ]]; then
    session_id="${BASH_REMATCH[1]}"
    session_name="${BASH_REMATCH[2]}"
    session_state="${BASH_REMATCH[3]}"
    session_count=$((session_count + 1))

    if [[ "$session_state" == "Detached" && "$session_name" =~ ^glasstunnel-terminal-[0-9]{10,}(-[A-Fa-f0-9]{4,12})?$ ]]; then
      candidate_count=$((candidate_count + 1))
      candidates+=("${session_id}.${session_name}")
    fi
  fi
done <<< "$SCREEN_LIST"

if [[ -n "$PROCESS_FILE" ]]; then
  PROCESS_LIST="$(cat "$PROCESS_FILE")"
else
  PROCESS_LIST="$(ps -axo pid,ppid,stat,command)"
fi

while IFS= read -r line; do
  if [[ "$line" =~ $process_line_re ]]; then
    process_id="${BASH_REMATCH[1]}"
    parent_id="${BASH_REMATCH[2]}"
    command="${BASH_REMATCH[3]}"
    executable="${command%% *}"
    executable_name="${executable##*/}"

    if [[ "$parent_id" == "1" && "$executable_name" == "screen" && "$command" == *" -xRR "* && "$command" =~ $attach_session_re ]]; then
      session_name="${BASH_REMATCH[2]}"
      if [[ "$session_name" == "glasstunnel-terminal" || "$session_name" =~ ^glasstunnel-terminal-[0-9]{10,}(-[A-Fa-f0-9]{4,12})?$ ]]; then
        orphan_client_count=$((orphan_client_count + 1))
        orphan_clients+=("${process_id}.${session_name}")
      fi
    fi
  fi
done <<< "$PROCESS_LIST"

echo "Glasstunnel Terminal screen-session cleanup audit"
echo "Sessions observed: $session_count"
echo "Detached generated cleanup candidates: $candidate_count"
echo "Orphan attach client candidates: $orphan_client_count"

if (( candidate_count > 0 )); then
  printf 'Candidates:\n'
  printf '  %s\n' "${candidates[@]}"
fi

if (( orphan_client_count > 0 )); then
  printf 'Orphan attach clients:\n'
  printf '  %s\n' "${orphan_clients[@]}"
fi

if [[ "$PRUNE" != "1" ]]; then
  echo "Result: dry-run; set GT_TERMINAL_SCREEN_CLEANUP_PRUNE=1 to quit cleanup candidates."
  exit 0
fi

if [[ -n "$LIST_FILE" || -n "$PROCESS_FILE" ]]; then
  echo "Result: dry-run; pruning is disabled when fixture input is used."
  exit 0
fi

if (( candidate_count > 0 )); then
  for session in "${candidates[@]}"; do
    "$SCREEN_BIN" -S "$session" -X quit || true
  done
fi

if (( orphan_client_count > 0 )); then
  for client in "${orphan_clients[@]}"; do
    kill "${client%%.*}" || true
  done
  sleep 0.2
  for client in "${orphan_clients[@]}"; do
    client_pid="${client%%.*}"
    if kill -0 "$client_pid" 2>/dev/null; then
      kill -9 "$client_pid" || true
    fi
  done
fi

echo "Result: pruned $candidate_count detached generated Glasstunnel screen session(s) and $orphan_client_count orphan attach client(s)."
