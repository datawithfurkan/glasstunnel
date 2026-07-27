# Telegram Blocker Notifications

Goal-loop agents can send a short Telegram message when progress is blocked on
real human action, such as a GUI approval, account creation, CAPTCHA, Keychain
prompt, missing app install, physical-phone test, or signing credential.

Notifications are optional and local-only. Bot tokens and chat ids must stay in
the local environment or an ignored `.env.*` file. Do not commit them.

## Setup

1. Create or open the Telegram bot.
2. Send `/start` or any short message to the bot from the Telegram account that
   should receive notifications.
3. Export the bot token locally:

```sh
export GT_TELEGRAM_BOT_TOKEN="<bot-token-from-botfather>"
```

4. Fetch the chat id:

```sh
pnpm notify:telegram:chat-id
```

5. Export the selected chat id:

```sh
export GT_TELEGRAM_CHAT_ID="<chat-id>"
```

Because `.env.*` is ignored, local shells can also source an untracked file:

```sh
cat > .env.telegram.local <<'EOF'
export GT_TELEGRAM_BOT_TOKEN="<bot-token-from-botfather>"
export GT_TELEGRAM_CHAT_ID="<chat-id>"
EOF

source .env.telegram.local
```

The notification scripts also auto-load `.env.telegram.local` from the repo
root, so long-running goal loops can call `pnpm notify:telegram:blocker`
directly once this file exists.

## Test

Run a dry run first:

```sh
GT_BLOCKER_TITLE="Dry run" \
GT_BLOCKER_BODY="No real message will be sent." \
GT_BLOCKER_ACTION="Confirm the text is concise and contains no secrets." \
pnpm notify:telegram:blocker:dry-run
```

Then send a real test:

```sh
GT_BLOCKER_TITLE="Telegram notifier test" \
GT_BLOCKER_BODY="Testing the Glasstunnel blocker notification path." \
GT_BLOCKER_ACTION="No action needed." \
pnpm notify:telegram:blocker
```

## Goal-Loop Usage

Use Telegram only when the driver is genuinely blocked on human action or an
external state change. Do not use it for ordinary test failures, code bugs, or
work that can still make progress through diagnostics.

Send at most one notification for the same blocker in an iteration:

```sh
GT_BLOCKER_TITLE="Claude Code install needs approval" \
GT_BLOCKER_BODY="The CLI installer opened a browser/account approval that must be completed by the user." \
GT_BLOCKER_ACTION="Complete the approval, then reply in Codex so the goal loop can continue." \
GT_BLOCKER_CONTEXT="Focus: Claude Code real-app verification." \
pnpm notify:telegram:blocker
```

Good notification content:

- The exact blocker.
- The human action required.
- The surface being tested.
- Whether the agent will rotate to another safe slice while waiting.

Never include:

- Bot tokens, API keys, passwords, private keys, Keychain values, auth codes, or
  one-time links.
- Personal email content, chat content, prompts, responses, or captured screen
  content.
- Long logs. Link to a local artifact or summarize the blocker instead.

If `GT_TELEGRAM_BOT_TOKEN` or `GT_TELEGRAM_CHAT_ID` is missing, the goal loop
should record that notification was skipped and continue with a safe non-stale
slice when possible.
