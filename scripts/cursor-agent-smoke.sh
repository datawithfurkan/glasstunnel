#!/usr/bin/env bash
# Privacy-safe Cursor Agent CLI smoke for release verification.
#
# Checks the local contracts the Cursor Agent card relies on: the CLI is
# installed and reports a version, its saved login state, the flags the card
# launches it with (--print, --output-format stream-json, --stream-partial-output,
# --resume, --mode, --model, --workspace, --trust, create-chat), the chat store
# layout under ~/.cursor/chats, and the Glasstunnel entries in ~/.cursor/hooks.json.
# It never sends a prompt, never reads chat content, and prints no paths outside
# the home-relative install locations.
#
# Set GT_CURSOR_AGENT_SMOKE_REQUIRE_LOGIN=1 to fail (instead of report) when the
# saved login is missing; the login itself must be done by a person with
# `cursor-agent login`.
set -euo pipefail

AGENT_PATH="${GT_CURSOR_AGENT_PATH:-}"
CURSOR_ROOT="${GT_CURSOR_ROOT:-$HOME/.cursor}"
HOOKS_FILE="${GT_CURSOR_HOOKS_FILE:-$CURSOR_ROOT/hooks.json}"
failures=0
blocked=0

row() {
  printf '| %s | %s | %s |\n' "$1" "$2" "$3"
}

fail() {
  row "$1" "fail" "$2"
  failures=$((failures + 1))
}

with_timeout() {
  local seconds="$1"
  shift
  perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
}

printf 'Glasstunnel Cursor Agent smoke\n'
printf 'Date: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf 'Commit: %s\n\n' "$(git rev-parse --short HEAD 2>/dev/null || printf unknown)"
printf '| Check | Result | Detail |\n'
printf '| --- | --- | --- |\n'

if [[ -z "$AGENT_PATH" ]]; then
  for candidate in cursor-agent "$HOME/.local/bin/cursor-agent" /opt/homebrew/bin/cursor-agent /usr/local/bin/cursor-agent; do
    if [[ "$candidate" == */* ]]; then
      [[ -x "$candidate" ]] && AGENT_PATH="$candidate" && break
    elif command -v "$candidate" >/dev/null 2>&1; then
      AGENT_PATH="$(command -v "$candidate")"
      break
    fi
  done
fi

if [[ -z "$AGENT_PATH" || ! -x "$AGENT_PATH" ]]; then
  fail "cursor-agent" "not installed in a location the card searches"
  printf '\nResult: failed; install Cursor Agent (curl https://cursor.com/install -fsS | bash) and rerun.\n'
  exit 1
fi
row "cursor-agent" "pass" "${AGENT_PATH/#$HOME/~}"

version="$(with_timeout 20 "$AGENT_PATH" --version 2>/dev/null | tail -n 1 | tr -d '\r' || true)"
if [[ -n "$version" ]]; then
  row "version" "pass" "$version"
else
  fail "version" "--version printed nothing"
fi

help="$(with_timeout 20 "$AGENT_PATH" --help 2>/dev/null || true)"
for flag in "--print" "--output-format" "stream-json" "--stream-partial-output" "--resume" "--mode" "--model" "--workspace" "--trust" "create-chat" "--list-models"; do
  if grep -Fq -- "$flag" <<<"$help"; then
    row "flag $flag" "pass" "advertised by --help"
  else
    fail "flag $flag" "missing from --help; the card launches the CLI with it"
  fi
done

status_output="$(with_timeout 25 "$AGENT_PATH" status 2>&1 | tr -d '\r' || true)"
if grep -Fqi "logged in" <<<"$status_output" && ! grep -Fqi "not logged in" <<<"$status_output"; then
  row "login" "pass" "saved login present (server acceptance is only proven by a prompt)"
else
  if [[ "${GT_CURSOR_AGENT_SMOKE_REQUIRE_LOGIN:-0}" == "1" ]]; then
    fail "login" "no saved login; run cursor-agent login"
  else
    row "login" "blocked" "no saved login; run cursor-agent login"
    blocked=$((blocked + 1))
  fi
fi

chats_root="$CURSOR_ROOT/chats"
if [[ -d "$chats_root" ]]; then
  workspace_dirs="$(find "$chats_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  stores="$(find "$chats_root" -mindepth 3 -maxdepth 3 -type f -name store.db 2>/dev/null | wc -l | tr -d ' ')"
  row "chat store" "pass" "$workspace_dirs workspace folders, $stores chat stores under ~/.cursor/chats"
else
  row "chat store" "pass" "no ~/.cursor/chats yet (created on the first chat)"
fi

trusted="$(find "$CURSOR_ROOT/projects" -mindepth 2 -maxdepth 2 -type f -name .workspace-trusted 2>/dev/null | wc -l | tr -d ' ')"
row "trusted workspaces" "pass" "$trusted records under ~/.cursor/projects (resolve chat folders)"

if [[ -f "$HOOKS_FILE" ]]; then
  if python3 - "$HOOKS_FILE" <<'PY'
import json, sys
try:
    config = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(2)
hooks = config.get("hooks") if isinstance(config, dict) else None
if not isinstance(hooks, dict):
    sys.exit(3)
events = ["beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure", "stop"]
missing = [e for e in events if not any("Glasstunnel/cursor.sock" in json.dumps(entry) for entry in hooks.get(e, []) or [])]
sys.exit(4 if missing else 0)
PY
  then
    row "hooks" "pass" "~/.cursor/hooks.json carries the Glasstunnel entries for the five events"
  else
    code=$?
    case "$code" in
      2) row "hooks" "blocked" "~/.cursor/hooks.json is not valid JSON; the card leaves it alone" ;;
      3) row "hooks" "blocked" "~/.cursor/hooks.json has no hooks object yet; either Cursor card installs it on start" ;;
      *) row "hooks" "blocked" "Glasstunnel entries not installed yet; either Cursor card installs them on start" ;;
    esac
    blocked=$((blocked + 1))
  fi
else
  row "hooks" "blocked" "no ~/.cursor/hooks.json yet; either Cursor card installs it on start"
  blocked=$((blocked + 1))
fi

printf '\n'
if [[ "$failures" -gt 0 ]]; then
  printf 'Result: failed; %d check(s) failed.\n' "$failures"
  exit 1
fi
if [[ "$blocked" -gt 0 ]]; then
  printf 'Result: partial; local contracts pass, %d check(s) need a person (login) or a card start (hooks).\n' "$blocked"
  exit 0
fi
printf 'Result: passed; Cursor Agent local contracts hold.\n'
