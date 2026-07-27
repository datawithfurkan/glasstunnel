#!/usr/bin/env bash
# Verify Codex CLI can render its TUI in a visible Terminal.app window attached
# to the same shared screen-session style Glasstunnel uses for Terminal.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_CODEX_CLI_TERMINAL_APP_TUI_OUT_DIR:-/tmp/glasstunnel-codex-cli-terminal-app-tui}"
WAIT_SECONDS="${GT_CODEX_CLI_TERMINAL_APP_TUI_WAIT:-20}"
SCREEN_WORKDIR="${GT_CODEX_CLI_TERMINAL_APP_TUI_WORKDIR:-$HOME}"
STAMP="$(date +%Y%m%d-%H%M%S)"
SESSION_NAME="glasstunnel-codex-cli-tui-${STAMP}-$$"
SESSION_MARKER="GT_CODEX_CLI_TUI_${STAMP}_$$"
COMMAND_FILE="${TMPDIR:-/tmp}/${SESSION_NAME}.command"
ARTIFACT="$OUT_DIR/codex-cli-terminal-app-tui-$STAMP.txt"
OSASCRIPT_ERR="$OUT_DIR/codex-cli-terminal-app-tui-$STAMP-osascript.err"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:codex-cli:terminal-app-tui

Opens Terminal.app into a unique shared screen session, starts Codex CLI in
interactive mode without sending a prompt, verifies Terminal.app's visible tab
contains Codex TUI text, then quits the session and records a local artifact.

This is local macOS GUI evidence. It does not prove mobile prompt delivery,
Codex model execution, hosted relay behavior, or physical-phone behavior.

Environment:
  GT_CODEX_CLI_TERMINAL_APP_TUI_OUT_DIR  Artifact directory.
  GT_CODEX_CLI_TERMINAL_APP_TUI_WAIT     Poll timeout in seconds. Default: 20.
  GT_CODEX_CLI_TERMINAL_APP_TUI_WORKDIR  Trusted Codex working directory. Default: HOME.
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
  echo "Result: skipped; Codex CLI Terminal.app TUI smoke requires macOS." >&2
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

codex_path="$(command -v codex 2>/dev/null || true)"
if [[ -z "$codex_path" ]]; then
  echo "Result: blocked; Codex CLI is not installed." >&2
  exit 1
fi

if [[ ! -d "$SCREEN_WORKDIR" ]]; then
  echo "Result: failed; Codex CLI Terminal.app TUI workdir does not exist: $SCREEN_WORKDIR" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

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
      if tabContents contains "$SESSION_NAME" or tabContents contains "$SESSION_MARKER" then
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
}
trap cleanup EXIT

codex_version="$(codex --version 2>/dev/null | sed -n '1p' || true)"

{
  printf 'Glasstunnel Codex CLI Terminal.app TUI smoke\n'
  printf 'Date: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf 'Commit: %s\n' "$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf unknown)"
  printf 'Codex path: %s\n' "${codex_path/#$HOME/~}"
  printf 'Codex version: %s\n' "${codex_version:-unknown}"
  printf 'Codex working directory: %s\n' "${SCREEN_WORKDIR/#$HOME/~}"
  printf 'Screen session: %s\n' "$SESSION_NAME"
  printf 'Marker: %s\n' "$SESSION_MARKER"
  printf 'Prompt sent: no\n'
} >"$ARTIFACT"

GT_CODEX_CLI_SMOKE_WORKDIR="$SCREEN_WORKDIR" \
  /usr/bin/screen -dmS "$SESSION_NAME" /bin/zsh -lc \
  'cd -- "$GT_CODEX_CLI_SMOKE_WORKDIR" && exec /bin/zsh -l'

cat >"$COMMAND_FILE" <<EOF
#!/bin/zsh
exec /usr/bin/screen -xRR -S $SESSION_NAME
EOF
chmod 700 "$COMMAND_FILE"

open -a Terminal "$COMMAND_FILE"
sleep 2

/usr/bin/screen -S "$SESSION_NAME" -X stuff "printf '$SESSION_MARKER\\n'$(printf '\r')"
/usr/bin/screen -S "$SESSION_NAME" -X stuff "TERM=xterm-256color codex --no-alt-screen -c check_for_update_on_startup=false --model gpt-5.5 --ask-for-approval never --sandbox read-only$(printf '\r')"

deadline=$((SECONDS + WAIT_SECONDS))
while (( SECONDS < deadline )); do
  contents="$(terminal_contents || true)"
  if printf '%s' "$contents" | grep -Eiq 'OpenAI Codex|Codex \(v|model:|/model to change|permissions:'; then
    {
      printf 'Phase passed: Terminal.app visible tab contained Codex TUI text.\n'
      printf 'Matched terms:\n'
      printf '%s\n' "$contents" | grep -Eio 'OpenAI Codex|Codex \(v[^)]*\)|model:|/model to change|permissions:' | sort -u
      printf 'Result: passed\n'
      printf 'Passed: Codex CLI opened in a visible Terminal.app shared screen session without sending a prompt.\n'
      printf 'Artifact: %s\n' "$ARTIFACT"
    } >>"$ARTIFACT"
    printf 'Result: passed; Codex CLI TUI rendered in visible Terminal.app shared session.\n'
    printf 'Artifact: %s\n' "$ARTIFACT"
    exit 0
  fi
  sleep 0.5
done

{
  printf 'Result: failed\n'
  printf 'Failed: Terminal.app did not expose expected Codex TUI text within %ss.\n' "$WAIT_SECONDS"
  printf 'Last visible Terminal.app contents excerpt:\n'
  terminal_contents 2>/dev/null | tail -40 || true
  printf 'osascript stderr:\n'
  cat "$OSASCRIPT_ERR" 2>/dev/null || true
} >>"$ARTIFACT"

echo "Result: failed; Terminal.app did not show expected Codex TUI text." >&2
echo "Artifact: $ARTIFACT" >&2
exit 1
