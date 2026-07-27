#!/usr/bin/env bash
# Verify Claude Code reaches a visible Terminal.app onboarding/TUI state when
# local runtime auth is not release-verified.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_CLAUDE_CODE_TERMINAL_APP_ONBOARDING_TUI_OUT_DIR:-/tmp/glasstunnel-claude-code-terminal-app-onboarding-tui}"
WAIT_SECONDS="${GT_CLAUDE_CODE_TERMINAL_APP_ONBOARDING_TUI_WAIT:-24}"
STAMP="$(date +%Y%m%d-%H%M%S)"
SESSION_NAME="glasstunnel-claude-onboarding-tui-${STAMP}-$$"
PROJECT_DIR="${TMPDIR:-/tmp}/${SESSION_NAME}-project"
COMMAND_FILE="${TMPDIR:-/tmp}/${SESSION_NAME}.command"
ARTIFACT="$OUT_DIR/claude-code-terminal-app-onboarding-tui-$STAMP.txt"
OSASCRIPT_ERR="$OUT_DIR/claude-code-terminal-app-onboarding-tui-$STAMP-osascript.err"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:claude-code:terminal-app-onboarding-tui

Opens Terminal.app into a unique shared screen session, starts Claude Code in
interactive safe mode without sending a prompt, and verifies Terminal.app's
visible tab contains Claude's onboarding/TUI state.

This is local macOS GUI evidence. It does not prove authenticated prompt
delivery, hook firing, model execution, hosted relay behavior, or
physical-phone behavior.

Environment:
  GT_CLAUDE_CODE_TERMINAL_APP_ONBOARDING_TUI_OUT_DIR  Artifact directory.
  GT_CLAUDE_CODE_TERMINAL_APP_ONBOARDING_TUI_WAIT     Poll timeout in seconds. Default: 24.
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
  echo "Result: skipped; Claude Code Terminal.app onboarding TUI smoke requires macOS." >&2
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

claude_path="$(command -v claude 2>/dev/null || true)"
if [[ -z "$claude_path" ]]; then
  echo "Result: blocked; Claude Code CLI is not installed." >&2
  exit 1
fi

mkdir -p "$OUT_DIR" "$PROJECT_DIR"

terminal_contents() {
  osascript 2>"$OSASCRIPT_ERR" <<'OSA'
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
      if tabContents contains "$SESSION_NAME" then
        close terminalWindow
      end if
    end try
  end repeat
end tell
OSA
}

cleanup() {
  /usr/bin/screen -S "$SESSION_NAME" -X quit >/dev/null 2>&1 || true
  close_matching_terminal_window
  rm -f "$COMMAND_FILE"
  rm -rf "$PROJECT_DIR"
}
trap cleanup EXIT

claude_version="$(claude --version 2>/dev/null | sed -n '1p' || true)"

{
  printf 'Glasstunnel Claude Code Terminal.app onboarding TUI smoke\n'
  printf 'Date: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf 'Commit: %s\n' "$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf unknown)"
  printf 'Claude path: %s\n' "${claude_path/#$HOME/~}"
  printf 'Claude version: %s\n' "${claude_version:-unknown}"
  printf 'Screen session: %s\n' "$SESSION_NAME"
  printf 'Project path: %s\n' "${PROJECT_DIR/#$HOME/~}"
  printf 'Prompt sent: no\n'
} >"$ARTIFACT"

/usr/bin/screen -dmS "$SESSION_NAME" /bin/zsh -l

cat >"$COMMAND_FILE" <<EOF
#!/bin/zsh
exec /usr/bin/screen -xRR -S $SESSION_NAME
EOF
chmod 700 "$COMMAND_FILE"

open -a Terminal "$COMMAND_FILE"
sleep 2

/usr/bin/screen -S "$SESSION_NAME" -X stuff "cd '$PROJECT_DIR'$(printf '\r')"
/usr/bin/screen -S "$SESSION_NAME" -X stuff "TERM=xterm-256color claude --safe-mode$(printf '\r')"

deadline=$((SECONDS + WAIT_SECONDS))
while (( SECONDS < deadline )); do
  contents="$(terminal_contents || true)"
  if printf '%s' "$contents" | grep -Eiq "Let's get started|Choose the text style|Syntax theme:|Claude Code|login|authentication|API key"; then
    {
      printf 'Phase passed: Terminal.app visible tab contained Claude Code onboarding/TUI text.\n'
      printf 'Matched terms:\n'
      printf '%s\n' "$contents" | grep -Eio "Let's get started|Choose the text style|Syntax theme:|Claude Code|login|authentication|API key|[0-9]+[.][0-9]+[.][0-9]+" | sort -u
      printf 'Result: passed\n'
      printf 'Passed: Claude Code opened in a visible Terminal.app shared screen session and reached an interactive onboarding/TUI state without sending a prompt.\n'
      printf 'Artifact: %s\n' "$ARTIFACT"
    } >>"$ARTIFACT"
    printf 'Result: passed; Claude Code onboarding/TUI rendered in visible Terminal.app shared session.\n'
    printf 'Artifact: %s\n' "$ARTIFACT"
    exit 0
  fi
  sleep 0.5
done

{
  printf 'Result: failed\n'
  printf 'Failed: Terminal.app did not expose expected Claude Code onboarding/TUI text within %ss.\n' "$WAIT_SECONDS"
  printf 'Last visible Terminal.app contents excerpt:\n'
  terminal_contents 2>/dev/null | tail -40 || true
  printf 'osascript stderr:\n'
  cat "$OSASCRIPT_ERR" 2>/dev/null || true
} >>"$ARTIFACT"

echo "Result: failed; Terminal.app did not show expected Claude Code onboarding/TUI text." >&2
echo "Artifact: $ARTIFACT" >&2
exit 1
