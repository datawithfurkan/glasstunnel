#!/usr/bin/env bash
# Send a concise Telegram message when a goal-loop iteration needs human action.
set -euo pipefail

if [[ -f ".env.telegram.local" ]]; then
  # Local-only secret file; ignored by git.
  # shellcheck disable=SC1091
  source ".env.telegram.local"
fi

API_BASE="${GT_TELEGRAM_API_BASE:-https://api.telegram.org}"
DRY_RUN="${GT_TELEGRAM_DRY_RUN:-0}"
DISABLED="${GT_TELEGRAM_DISABLE:-0}"
TITLE="${GT_BLOCKER_TITLE:-Glasstunnel goal loop needs human action}"
SEVERITY="${GT_BLOCKER_SEVERITY:-blocked}"
BODY="${GT_BLOCKER_BODY:-}"
ACTION="${GT_BLOCKER_ACTION:-Please check the Codex thread and complete the required manual step.}"
CONTEXT="${GT_BLOCKER_CONTEXT:-}"
CWD_VALUE="${GT_BLOCKER_CWD:-${PWD}}"
COMMIT_VALUE="${GT_BLOCKER_COMMIT:-}"
TOPIC_ID="${GT_TELEGRAM_TOPIC_ID:-}"

usage() {
  cat <<'USAGE'
Usage: GT_BLOCKER_TITLE="..." GT_BLOCKER_BODY="..." pnpm notify:telegram:blocker

Sends a Telegram blocker notification for goal-loop work that genuinely needs
human action.

Required environment unless GT_TELEGRAM_DRY_RUN=1:
  GT_TELEGRAM_BOT_TOKEN   Telegram bot token from BotFather.
  GT_TELEGRAM_CHAT_ID     Target Telegram chat id.
  These may also be set in a gitignored .env.telegram.local file.

Optional environment:
  GT_BLOCKER_TITLE        Short notification title.
  GT_BLOCKER_BODY         What is blocked.
  GT_BLOCKER_ACTION       What the human should do next.
  GT_BLOCKER_CONTEXT      Extra non-secret context.
  GT_BLOCKER_SEVERITY     blocked, needs-action, warning, etc.
  GT_BLOCKER_CWD          Repo/workspace path. Defaults to current directory.
  GT_BLOCKER_COMMIT       Commit or branch, if useful.
  GT_TELEGRAM_TOPIC_ID    Optional Telegram forum topic/thread id.
  GT_TELEGRAM_DISABLE=1   Skip sending and exit successfully.
  GT_TELEGRAM_DRY_RUN=1   Print the message instead of sending.

Never include tokens, passwords, private keys, auth links, or personal content
in the blocker message.
USAGE
}

if [[ "${1:-}" == "--" ]]; then
  shift
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$DISABLED" == "1" ]]; then
  echo "Telegram blocker notification skipped because GT_TELEGRAM_DISABLE=1."
  exit 0
fi

append_line() {
  local label="$1"
  local value="$2"
  if [[ -n "$value" ]]; then
    MESSAGE+="${label}: ${value}"$'\n'
  fi
}

MESSAGE="Glasstunnel needs human action"$'\n'
append_line "Severity" "$SEVERITY"
append_line "Title" "$TITLE"
append_line "Workspace" "$CWD_VALUE"
append_line "Commit" "$COMMIT_VALUE"
append_line "Blocked on" "$BODY"
append_line "Needed" "$ACTION"
append_line "Context" "$CONTEXT"

MAX_LEN=3900
if (( ${#MESSAGE} > MAX_LEN )); then
  MESSAGE="${MESSAGE:0:MAX_LEN}"$'\n'"..."
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Telegram blocker notification dry run:"
  printf '%s\n' "$MESSAGE"
  exit 0
fi

if [[ -z "${GT_TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "GT_TELEGRAM_BOT_TOKEN is required. See docs/telegram-blocker-notifications.md." >&2
  exit 2
fi

if [[ -z "${GT_TELEGRAM_CHAT_ID:-}" ]]; then
  echo "GT_TELEGRAM_CHAT_ID is required. Run pnpm notify:telegram:chat-id after messaging the bot." >&2
  exit 2
fi

response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT

curl_args=(
  -sS
  -o "$response_file"
  -w "%{http_code}"
  --connect-timeout 10
  --max-time 20
  -X POST
  "${API_BASE}/bot${GT_TELEGRAM_BOT_TOKEN}/sendMessage"
  --data-urlencode "chat_id=${GT_TELEGRAM_CHAT_ID}"
  --data-urlencode "text=${MESSAGE}"
  --data-urlencode "disable_web_page_preview=true"
)

if [[ -n "$TOPIC_ID" ]]; then
  curl_args+=(--data-urlencode "message_thread_id=${TOPIC_ID}")
fi

http_code="$(curl "${curl_args[@]}")"
if [[ "$http_code" != "200" ]]; then
  echo "Telegram blocker notification failed with HTTP ${http_code}." >&2
  if [[ -s "$response_file" ]]; then
    sed -E 's/"token":"[^"]+"/"token":"[redacted]"/g' "$response_file" >&2 || true
    echo >&2
  fi
  exit 1
fi

echo "Telegram blocker notification sent."
