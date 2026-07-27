#!/usr/bin/env bash
# Verify Gemini CLI reaches its visible Terminal.app auth/TUI state when local
# auth is not configured.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_GEMINI_TERMINAL_APP_AUTH_TUI_OUT_DIR:-/tmp/glasstunnel-gemini-terminal-app-auth-tui}"
WAIT_SECONDS="${GT_GEMINI_TERMINAL_APP_AUTH_TUI_WAIT:-24}"
STAMP="$(date +%Y%m%d-%H%M%S)"
SESSION_NAME="glasstunnel-gemini-auth-tui-${STAMP}-$$"
PROJECT_DIR="${TMPDIR:-/tmp}/${SESSION_NAME}-project"
COMMAND_FILE="${TMPDIR:-/tmp}/${SESSION_NAME}.command"
ARTIFACT="$OUT_DIR/gemini-cli-terminal-app-auth-tui-$STAMP.txt"
OSASCRIPT_ERR="$OUT_DIR/gemini-cli-terminal-app-auth-tui-$STAMP-osascript.err"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:gemini-cli:terminal-app-auth-tui

Opens Terminal.app into a unique shared screen session, starts Gemini CLI in
interactive mode without sending a prompt, and verifies Terminal.app's visible
tab contains Gemini's auth/TUI state.

This is local macOS GUI evidence. It does not prove authenticated prompt
delivery, model execution, hosted relay behavior, or physical-phone behavior.

Environment:
  GT_GEMINI_TERMINAL_APP_AUTH_TUI_OUT_DIR  Artifact directory.
  GT_GEMINI_TERMINAL_APP_AUTH_TUI_WAIT     Poll timeout in seconds. Default: 24.
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
  echo "Result: skipped; Gemini CLI Terminal.app auth TUI smoke requires macOS." >&2
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

gemini_path="$(command -v gemini 2>/dev/null || true)"
if [[ -z "$gemini_path" ]]; then
  echo "Result: blocked; Gemini CLI is not installed." >&2
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

gemini_version="$(gemini --version 2>/dev/null | sed -n '1p' || true)"

{
  printf 'Glasstunnel Gemini CLI Terminal.app auth TUI smoke\n'
  printf 'Date: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf 'Commit: %s\n' "$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf unknown)"
  printf 'Gemini path: %s\n' "${gemini_path/#$HOME/~}"
  printf 'Gemini version: %s\n' "${gemini_version:-unknown}"
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
/usr/bin/screen -S "$SESSION_NAME" -X stuff "TERM=xterm-256color gemini --skip-trust$(printf '\r')"

deadline=$((SECONDS + WAIT_SECONDS))
while (( SECONDS < deadline )); do
  contents="$(terminal_contents || true)"
  if printf '%s' "$contents" | grep -Eiq 'How would you like to authenticate|Sign in with Google|Use Gemini API Key|No authentication method selected|Gemini CLI'; then
    {
      printf 'Phase passed: Terminal.app visible tab contained Gemini auth/TUI text.\n'
      printf 'Matched terms:\n'
      printf '%s\n' "$contents" | grep -Eio 'How would you like to authenticate|Sign in with Google|Use Gemini API Key|No authentication method selected|Gemini CLI|[0-9]+[.][0-9]+[.][0-9]+' | sort -u
      printf 'Result: passed\n'
      printf 'Passed: Gemini CLI opened in a visible Terminal.app shared screen session and reached an interactive auth/TUI state without sending a prompt.\n'
      printf 'Artifact: %s\n' "$ARTIFACT"
    } >>"$ARTIFACT"
    printf 'Result: passed; Gemini CLI auth/TUI rendered in visible Terminal.app shared session.\n'
    printf 'Artifact: %s\n' "$ARTIFACT"
    exit 0
  fi
  sleep 0.5
done

{
  printf 'Result: failed\n'
  printf 'Failed: Terminal.app did not expose expected Gemini auth/TUI text within %ss.\n' "$WAIT_SECONDS"
  printf 'Last visible Terminal.app contents excerpt:\n'
  terminal_contents 2>/dev/null | tail -40 || true
  printf 'osascript stderr:\n'
  cat "$OSASCRIPT_ERR" 2>/dev/null || true
} >>"$ARTIFACT"

echo "Result: failed; Terminal.app did not show expected Gemini auth/TUI text." >&2
echo "Artifact: $ARTIFACT" >&2
exit 1
