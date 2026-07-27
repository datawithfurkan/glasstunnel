#!/usr/bin/env bash
# Print recent Telegram chat ids for the configured bot.
set -euo pipefail

if [[ -f ".env.telegram.local" ]]; then
  # Local-only secret file; ignored by git.
  # shellcheck disable=SC1091
  source ".env.telegram.local"
fi

API_BASE="${GT_TELEGRAM_API_BASE:-https://api.telegram.org}"

usage() {
  cat <<'USAGE'
Usage: GT_TELEGRAM_BOT_TOKEN="..." pnpm notify:telegram:chat-id

After sending a message such as /start to the Telegram bot, this command prints
recent chat ids from getUpdates. Copy the right id into GT_TELEGRAM_CHAT_ID.

Required environment:
  GT_TELEGRAM_BOT_TOKEN   Telegram bot token from BotFather.
  This may also be set in a gitignored .env.telegram.local file.
USAGE
}

if [[ "${1:-}" == "--" ]]; then
  shift
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${GT_TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "GT_TELEGRAM_BOT_TOKEN is required." >&2
  exit 2
fi

updates_file="$(mktemp)"
trap 'rm -f "$updates_file"' EXIT

if ! curl -fsS --connect-timeout 10 --max-time 20 \
  "${API_BASE}/bot${GT_TELEGRAM_BOT_TOKEN}/getUpdates" \
  -o "$updates_file"; then
  echo "Could not fetch Telegram updates. Verify the token and message the bot first." >&2
  exit 1
fi

node - "$updates_file" <<'NODE'
const fs = require("fs");
const path = process.argv[2];
const payload = JSON.parse(fs.readFileSync(path, "utf8"));

if (!payload.ok) {
  const description = payload.description || "Telegram returned ok=false";
  console.error(description);
  process.exit(1);
}

const chats = new Map();
for (const update of payload.result || []) {
  const message =
    update.message ||
    update.edited_message ||
    update.channel_post ||
    update.edited_channel_post ||
    update.callback_query?.message;
  const chat = message?.chat;
  if (!chat || chat.id === undefined) continue;
  chats.set(String(chat.id), {
    id: chat.id,
    type: chat.type || "unknown",
    title: chat.title || [chat.first_name, chat.last_name].filter(Boolean).join(" ") || chat.username || "",
    username: chat.username || "",
    updateId: update.update_id,
  });
}

if (chats.size === 0) {
  console.log("No recent Telegram chats found. Send /start or any message to the bot, then run this command again.");
  process.exit(0);
}

console.log("Recent Telegram chats:");
for (const chat of chats.values()) {
  const label = chat.title ? ` ${chat.title}` : "";
  const username = chat.username ? ` @${chat.username}` : "";
  console.log(`- chat_id=${chat.id} type=${chat.type}${label}${username} latest_update=${chat.updateId}`);
}
NODE
