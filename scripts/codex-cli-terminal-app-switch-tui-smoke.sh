#!/usr/bin/env bash
# Verify Codex CLI TUI survives switching away to another shared Terminal.app
# screen session and reattaching.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_CODEX_CLI_TERMINAL_APP_SWITCH_TUI_OUT_DIR:-/tmp/glasstunnel-codex-cli-terminal-app-switch-tui}"
WAIT_SECONDS="${GT_CODEX_CLI_TERMINAL_APP_SWITCH_TUI_WAIT:-24}"
SCREEN_WORKDIR="${GT_CODEX_CLI_TERMINAL_APP_SWITCH_TUI_WORKDIR:-$HOME}"
STAMP="$(date +%Y%m%d-%H%M%S)"
SHELL_SESSION_NAME="glasstunnel-codex-switch-shell-${STAMP}-$$"
CODEX_SESSION_NAME="glasstunnel-codex-switch-tui-${STAMP}-$$"
SHELL_MARKER="GT_CODEX_SWITCH_SHELL_${STAMP}_$$"
CODEX_MARKER="GT_CODEX_SWITCH_TUI_${STAMP}_$$"
SHELL_COMMAND_FILE="${TMPDIR:-/tmp}/${SHELL_SESSION_NAME}.command"
CODEX_COMMAND_FILE="${TMPDIR:-/tmp}/${CODEX_SESSION_NAME}.command"
ARTIFACT="$OUT_DIR/codex-cli-terminal-app-switch-tui-$STAMP.txt"
OSASCRIPT_ERR="$OUT_DIR/codex-cli-terminal-app-switch-tui-$STAMP-osascript.err"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:codex-cli:terminal-app-switch-tui

Opens Terminal.app into a normal shared shell session, opens Codex CLI in a
second shared screen session, switches back to the shell session, then
reattaches Codex and verifies the visible TUI is still recoverable.

This is local macOS GUI evidence. It does not prove mobile prompt delivery,
Codex model execution, hosted relay behavior, or physical-phone behavior.

Environment:
  GT_CODEX_CLI_TERMINAL_APP_SWITCH_TUI_OUT_DIR  Artifact directory.
  GT_CODEX_CLI_TERMINAL_APP_SWITCH_TUI_WAIT     Poll timeout in seconds. Default: 24.
  GT_CODEX_CLI_TERMINAL_APP_SWITCH_TUI_WORKDIR  Trusted Codex working directory. Default: HOME.
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
  echo "Result: skipped; Codex CLI Terminal.app switch TUI smoke requires macOS." >&2
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
  echo "Result: failed; Codex CLI Terminal.app switch TUI workdir does not exist: $SCREEN_WORKDIR" >&2
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
      if tabContents contains "$SHELL_SESSION_NAME" or tabContents contains "$CODEX_SESSION_NAME" or tabContents contains "$SHELL_MARKER" or tabContents contains "$CODEX_MARKER" then
        close terminalWindow
      end if
    end try
  end repeat
end tell
OSA
}

cleanup() {
  /usr/bin/screen -S "$SHELL_SESSION_NAME" -X quit >/dev/null 2>&1 || true
  /usr/bin/screen -S "$CODEX_SESSION_NAME" -X quit >/dev/null 2>&1 || true
  close_matching_terminal_window
  rm -f "$SHELL_COMMAND_FILE" "$CODEX_COMMAND_FILE"
}
trap cleanup EXIT

codex_version="$(codex --version 2>/dev/null | sed -n '1p' || true)"

{
  printf 'Glasstunnel Codex CLI Terminal.app switch TUI smoke\n'
  printf 'Date: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf 'Commit: %s\n' "$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf unknown)"
  printf 'Codex path: %s\n' "${codex_path/#$HOME/~}"
  printf 'Codex version: %s\n' "${codex_version:-unknown}"
  printf 'Codex working directory: %s\n' "${SCREEN_WORKDIR/#$HOME/~}"
  printf 'Shell session: %s\n' "$SHELL_SESSION_NAME"
  printf 'Codex session: %s\n' "$CODEX_SESSION_NAME"
  printf 'Shell marker: %s\n' "$SHELL_MARKER"
  printf 'Codex marker: %s\n' "$CODEX_MARKER"
  printf 'Prompt sent: no\n'
} >"$ARTIFACT"

GT_CODEX_CLI_SMOKE_WORKDIR="$SCREEN_WORKDIR" \
  /usr/bin/screen -dmS "$SHELL_SESSION_NAME" /bin/zsh -lc \
  'cd -- "$GT_CODEX_CLI_SMOKE_WORKDIR" && exec /bin/zsh -l'
GT_CODEX_CLI_SMOKE_WORKDIR="$SCREEN_WORKDIR" \
  /usr/bin/screen -dmS "$CODEX_SESSION_NAME" /bin/zsh -lc \
  'cd -- "$GT_CODEX_CLI_SMOKE_WORKDIR" && exec /bin/zsh -l'

cat >"$SHELL_COMMAND_FILE" <<EOF
#!/bin/zsh
exec /usr/bin/screen -xRR -S $SHELL_SESSION_NAME
EOF
chmod 700 "$SHELL_COMMAND_FILE"

cat >"$CODEX_COMMAND_FILE" <<EOF
#!/bin/zsh
exec /usr/bin/screen -xRR -S $CODEX_SESSION_NAME
EOF
chmod 700 "$CODEX_COMMAND_FILE"

wait_for_visible() {
  local phase="$1"
  local expected_regex="$2"
  local forbidden_regex="${3:-}"

  deadline=$((SECONDS + WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    contents="$(terminal_contents || true)"
    if printf '%s' "$contents" | grep -Eiq "$expected_regex"; then
      if [[ -n "$forbidden_regex" ]] && printf '%s' "$contents" | grep -Eiq "$forbidden_regex"; then
        {
          printf 'Result: failed\n'
          printf 'Failed: phase %s showed expected pattern but also stale forbidden pattern.\n' "$phase"
          printf 'Expected regex: %s\n' "$expected_regex"
          printf 'Forbidden regex: %s\n' "$forbidden_regex"
        } >>"$ARTIFACT"
        echo "Result: failed; Terminal.app phase $phase showed stale forbidden pattern." >&2
        echo "Artifact: $ARTIFACT" >&2
        exit 1
      fi
      printf 'Phase passed: %s matched %s\n' "$phase" "$expected_regex" >>"$ARTIFACT"
      return
    fi
    sleep 0.5
  done

  {
    printf 'Result: failed\n'
    printf 'Failed: Terminal.app did not match %s during %s within %ss.\n' "$expected_regex" "$phase" "$WAIT_SECONDS"
    printf 'Last visible Terminal.app contents excerpt:\n'
    terminal_contents 2>/dev/null | tail -50 || true
    printf 'osascript stderr:\n'
    cat "$OSASCRIPT_ERR" 2>/dev/null || true
  } >>"$ARTIFACT"

  echo "Result: failed; Terminal.app did not match expected pattern during $phase." >&2
  echo "Artifact: $ARTIFACT" >&2
  exit 1
}

open -a Terminal "$SHELL_COMMAND_FILE"
sleep 2
/usr/bin/screen -S "$SHELL_SESSION_NAME" -X stuff "printf '$SHELL_MARKER\\n'$(printf '\r')"
wait_for_visible "shell attach" "$SHELL_MARKER"

open -a Terminal "$CODEX_COMMAND_FILE"
sleep 2
/usr/bin/screen -S "$CODEX_SESSION_NAME" -X stuff "printf '$CODEX_MARKER\\n'$(printf '\r')"
/usr/bin/screen -S "$CODEX_SESSION_NAME" -X stuff "TERM=xterm-256color codex --no-alt-screen -c check_for_update_on_startup=false --model gpt-5.5 --ask-for-approval never --sandbox read-only$(printf '\r')"
wait_for_visible "codex first attach" 'OpenAI Codex|Codex \(v|model:|/model to change|permissions:' "$SHELL_MARKER"

open -a Terminal "$SHELL_COMMAND_FILE"
sleep 2
wait_for_visible "shell reattach" "$SHELL_MARKER" 'OpenAI Codex|Codex \(v|model:|/model to change|permissions:'

open -a Terminal "$CODEX_COMMAND_FILE"
sleep 2
wait_for_visible "codex reattach after shell switch" 'OpenAI Codex|Codex \(v|model:|/model to change|permissions:' "$SHELL_MARKER"

{
  printf 'Result: passed\n'
  printf 'Passed: Codex CLI TUI opened in a visible shared Terminal.app session, survived switching away to a normal shell session, and reattached without stale shell output.\n'
  printf 'Artifact: %s\n' "$ARTIFACT"
} >>"$ARTIFACT"

printf 'Result: passed; Codex CLI TUI reattached after Terminal.app session switching.\n'
printf 'Artifact: %s\n' "$ARTIFACT"
