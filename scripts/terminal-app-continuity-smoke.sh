#!/usr/bin/env bash
# Verify Terminal.app can visibly attach to the same screen sessions used by
# Glasstunnel's Terminal adapter.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_TERMINAL_APP_CONTINUITY_OUT_DIR:-/tmp/glasstunnel-terminal-app-continuity}"
WAIT_SECONDS="${GT_TERMINAL_APP_CONTINUITY_WAIT:-12}"
STAMP="$(date +%Y%m%d-%H%M%S)"
PRIMARY_SESSION_NAME="glasstunnel-terminal-gui-${STAMP}-primary-$$"
SECONDARY_SESSION_NAME="glasstunnel-terminal-gui-${STAMP}-secondary-$$"
PRIMARY_MARKER="GT_TERMINAL_APP_PRIMARY_${STAMP}_$$"
SECONDARY_MARKER="GT_TERMINAL_APP_SECONDARY_${STAMP}_$$"
PRIMARY_COMMAND_FILE="${TMPDIR:-/tmp}/${PRIMARY_SESSION_NAME}.command"
SECONDARY_COMMAND_FILE="${TMPDIR:-/tmp}/${SECONDARY_SESSION_NAME}.command"
ARTIFACT="$OUT_DIR/terminal-app-continuity-$STAMP.txt"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:terminal:app-continuity

Opens Terminal.app into two unique shared screen sessions, sends marker
commands into each session, verifies the markers appear in Terminal.app's
visible tab contents, and verifies reattaching the first session restores the
first marker instead of stale output from the second session.

This is local macOS GUI evidence. It does not prove hosted mobile command
delivery, physical-phone behavior, or full-screen CLI TUI correctness.

Environment:
  GT_TERMINAL_APP_CONTINUITY_OUT_DIR  Artifact directory.
  GT_TERMINAL_APP_CONTINUITY_WAIT     Poll timeout in seconds. Default: 12.
USAGE
}

if [[ "${1:-}" == "--" ]]; then
  shift
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Result: skipped; Terminal.app continuity smoke requires macOS." >&2
  exit 1
fi

if [[ ! -x /usr/bin/screen ]]; then
  echo "Result: failed; /usr/bin/screen is not executable." >&2
  exit 1
fi

if ! command -v osascript >/dev/null 2>&1; then
  echo "Result: failed; osascript is required to inspect Terminal.app." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

terminal_contents() {
  osascript <<'OSA' 2>/tmp/glasstunnel-terminal-app-continuity-osascript.err
tell application "Terminal"
  if (count of windows) is 0 then
    return ""
  end if
  return contents of selected tab of front window
end tell
OSA
}

close_matching_terminal_window() {
  osascript <<OSA >/dev/null 2>&1 || true
tell application "Terminal"
  repeat with terminalWindow in windows
    try
      set tabContents to contents of selected tab of terminalWindow
      if tabContents contains "$PRIMARY_SESSION_NAME" or tabContents contains "$SECONDARY_SESSION_NAME" or tabContents contains "$PRIMARY_MARKER" or tabContents contains "$SECONDARY_MARKER" then
        close terminalWindow
      end if
    end try
  end repeat
end tell
OSA
}

cleanup() {
  /usr/bin/screen -S "$PRIMARY_SESSION_NAME" -X quit >/dev/null 2>&1 || true
  /usr/bin/screen -S "$SECONDARY_SESSION_NAME" -X quit >/dev/null 2>&1 || true
  close_matching_terminal_window
  rm -f "$PRIMARY_COMMAND_FILE" "$SECONDARY_COMMAND_FILE"
}
trap cleanup EXIT

{
  printf 'Glasstunnel Terminal.app continuity smoke\n'
  printf 'Date: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf 'Commit: %s\n' "$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf unknown)"
  printf 'Primary session: %s\n' "$PRIMARY_SESSION_NAME"
  printf 'Secondary session: %s\n' "$SECONDARY_SESSION_NAME"
  printf 'Primary marker: %s\n' "$PRIMARY_MARKER"
  printf 'Secondary marker: %s\n' "$SECONDARY_MARKER"
} >"$ARTIFACT"

/usr/bin/screen -dmS "$PRIMARY_SESSION_NAME" /bin/zsh -l
/usr/bin/screen -dmS "$SECONDARY_SESSION_NAME" /bin/zsh -l

cat >"$PRIMARY_COMMAND_FILE" <<EOF
#!/bin/zsh
exec /usr/bin/screen -xRR -S $PRIMARY_SESSION_NAME
EOF
chmod 700 "$PRIMARY_COMMAND_FILE"

cat >"$SECONDARY_COMMAND_FILE" <<EOF
#!/bin/zsh
exec /usr/bin/screen -xRR -S $SECONDARY_SESSION_NAME
EOF
chmod 700 "$SECONDARY_COMMAND_FILE"

wait_for_terminal_marker() {
  local phase="$1"
  local expected="$2"
  local forbidden="${3:-}"

  deadline=$((SECONDS + WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    contents="$(terminal_contents || true)"
    if printf '%s' "$contents" | grep -q "$expected"; then
      if [[ -n "$forbidden" ]] && printf '%s' "$contents" | grep -q "$forbidden"; then
        {
          printf 'Result: failed\n'
          printf 'Failed: phase %s showed expected marker %s but also stale marker %s.\n' "$phase" "$expected" "$forbidden"
        } >>"$ARTIFACT"
        echo "Result: failed; Terminal.app phase $phase showed stale marker $forbidden." >&2
        echo "Artifact: $ARTIFACT" >&2
        exit 1
      fi
      printf 'Phase passed: %s showed %s\n' "$phase" "$expected" >>"$ARTIFACT"
      return
    fi
    sleep 0.5
  done

  {
    printf 'Result: failed\n'
    printf 'Failed: Terminal.app did not show marker %s during %s within %ss.\n' "$expected" "$phase" "$WAIT_SECONDS"
    printf 'osascript stderr:\n'
    cat /tmp/glasstunnel-terminal-app-continuity-osascript.err 2>/dev/null || true
  } >>"$ARTIFACT"

  echo "Result: failed; Terminal.app did not show marker $expected during $phase." >&2
  echo "Artifact: $ARTIFACT" >&2
  exit 1
}

open -a Terminal "$PRIMARY_COMMAND_FILE"
sleep 2
/usr/bin/screen -S "$PRIMARY_SESSION_NAME" -X stuff "printf '$PRIMARY_MARKER\\n'$(printf '\r')"
wait_for_terminal_marker "primary attach" "$PRIMARY_MARKER"

open -a Terminal "$SECONDARY_COMMAND_FILE"
sleep 2
/usr/bin/screen -S "$SECONDARY_SESSION_NAME" -X stuff "printf '$SECONDARY_MARKER\\n'$(printf '\r')"
wait_for_terminal_marker "secondary attach" "$SECONDARY_MARKER" "$PRIMARY_MARKER"

open -a Terminal "$PRIMARY_COMMAND_FILE"
sleep 2
wait_for_terminal_marker "primary reattach" "$PRIMARY_MARKER" "$SECONDARY_MARKER"

{
  printf 'Result: passed\n'
  printf 'Passed: Terminal.app displayed isolated markers for two distinct shared screen sessions and reattached the primary session without stale secondary output.\n'
  printf 'Artifact: %s\n' "$ARTIFACT"
} >>"$ARTIFACT"

printf 'Result: passed; Terminal.app visible tabs attach and reattach shared screen sessions without stale cross-session output.\n'
printf 'Artifact: %s\n' "$ARTIFACT"
