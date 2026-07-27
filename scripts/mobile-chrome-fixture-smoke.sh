#!/usr/bin/env bash
# Capture local mobile workspace fixture screenshots in Chrome's mobile-sized viewport.
#
# This is local visual QA only. It does not require a signed-in account, live
# Mac app or real phone. Hardware evidence remains separate when a named gate
# explicitly requires it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${GT_MOBILE_CHROME_FIXTURE_PORT:-5176}"
WAIT_MS="${GT_MOBILE_CHROME_FIXTURE_WAIT_MS:-3000}"
SCREENSHOT_TIMEOUT_SECONDS="${GT_MOBILE_CHROME_SCREENSHOT_TIMEOUT:-45}"
WIDTH="${GT_MOBILE_CHROME_WIDTH:-390}"
HEIGHT="${GT_MOBILE_CHROME_HEIGHT:-844}"
OUT_DIR="${GT_MOBILE_CHROME_OUT_DIR:-/tmp/glasstunnel-mobile-qa}"
SERVER_LOG="${TMPDIR:-/tmp}/glasstunnel-mobile-chrome-fixture-vite.log"
CHROME_LOG="${TMPDIR:-/tmp}/glasstunnel-mobile-chrome-fixture-chrome.log"
CHROME_BIN="${GT_MOBILE_CHROME_BIN:-}"

fixtures=(
  hosts-empty
  hosts-mixed
  workspace-empty
  workspace-single-app
  workspace-multi-app
  workspace-all-apps
  workspace-screen-offline
  workspace-screen-stopping
  workspace-terminal-stopped
  workspace-terminal-running
  workspace-codex-cli-stopped
  workspace-codex-cli-starting
  workspace-codex-cli-running
  workspace-codex-target-unverified
  workspace-cursor-generated-labels
  workspace-cursor-agent-running
  workspace-opencode-running
  workspace-gemini-cli-running
  workspace-claude-code-running
  workspace-offline-cached
)

if [[ -n "${GT_MOBILE_CHROME_FIXTURES:-}" ]]; then
  IFS=', ' read -r -a fixtures <<<"$GT_MOBILE_CHROME_FIXTURES"
fi

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${CHROME_PROFILE:-}" ]]; then
    rm -rf "$CHROME_PROFILE"
  fi
}
trap cleanup EXIT

run_with_timeout() {
  local timeout_seconds="$1"
  shift
  "$@" &
  local command_pid=$!
  (
    sleep "$timeout_seconds"
    kill "$command_pid" >/dev/null 2>&1 || true
  ) &
  local watchdog_pid=$!

  local status=0
  wait "$command_pid" || status=$?
  kill "$watchdog_pid" >/dev/null 2>&1 || true
  wait "$watchdog_pid" >/dev/null 2>&1 || true

  return "$status"
}

if [[ -z "$CHROME_BIN" ]]; then
  if [[ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]]; then
    CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  elif command -v google-chrome >/dev/null 2>&1; then
    CHROME_BIN="$(command -v google-chrome)"
  elif command -v chromium >/dev/null 2>&1; then
    CHROME_BIN="$(command -v chromium)"
  fi
fi

if [[ -z "$CHROME_BIN" || ! -x "$CHROME_BIN" ]]; then
  echo "Chrome executable not found. Set GT_MOBILE_CHROME_BIN to run this smoke." >&2
  exit 1
fi

cd "$ROOT_DIR"
mkdir -p "$OUT_DIR"
CHROME_PROFILE="$(mktemp -d "${TMPDIR:-/tmp}/glasstunnel-mobile-chrome-profile.XXXXXX")"

echo "Glasstunnel mobile Chrome fixture smoke"
echo "Repo: $ROOT_DIR"
echo "Commit: $(git rev-parse --short HEAD 2>/dev/null || printf unknown)"
echo "Chrome: $("$CHROME_BIN" --version 2>/dev/null || printf unknown)"
echo "Viewport: ${WIDTH}x${HEIGHT}"
echo "Port: $PORT"
echo

dump_dom() {
  local fixture="$1"
  local url="$2"
  local dom_file="$OUT_DIR/chrome-mobile-${fixture}-${timestamp}.html"

  if ! run_with_timeout "$SCREENSHOT_TIMEOUT_SECONDS" "$CHROME_BIN" \
    --headless=new \
    --disable-gpu \
    --disable-background-networking \
    --disable-component-update \
    --disable-sync \
    --disable-extensions \
    --disable-default-apps \
    --disable-crash-reporter \
    --disable-breakpad \
    --metrics-recording-only \
    --disable-features=MediaRouter,OptimizationHints,AutofillServerCommunication,CertificateTransparencyComponentUpdater \
    --hide-scrollbars \
    --log-level=3 \
    --no-first-run \
    --no-default-browser-check \
    --user-data-dir="$CHROME_PROFILE" \
    --window-size="${WIDTH},${HEIGHT}" \
    --force-device-scale-factor=2 \
    --user-agent="Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/149.0.0.0 Mobile/15E148 Safari/604.1" \
    --virtual-time-budget="$WAIT_MS" \
    --run-all-compositor-stages-before-draw \
    --dump-dom \
    "$url" >"$dom_file" 2>>"$CHROME_LOG"; then
    echo "Chrome DOM dump failed or timed out for fixture '$fixture'." >&2
    echo "Chrome log: $CHROME_LOG" >&2
    exit 1
  fi

  printf '%s\n' "$dom_file"
}

first_offset() {
  local pattern="$1"
  local file="$2"
  local offset

  offset="$(grep -abo "$pattern" "$file" | head -n 1 | cut -d: -f1 || true)"
  if [[ -z "$offset" ]]; then
    echo "Missing expected text '$pattern' in DOM dump: $file" >&2
    exit 1
  fi
  printf '%s\n' "$offset"
}

first_offset_after() {
  local pattern="$1"
  local file="$2"
  local min_offset="$3"
  local offset

  offset="$(grep -abo "$pattern" "$file" | awk -F: -v min="$min_offset" '$1 > min { print $1; exit }' || true)"
  if [[ -z "$offset" ]]; then
    echo "Missing expected text '$pattern' after offset $min_offset in DOM dump: $file" >&2
    exit 1
  fi
  printf '%s\n' "$offset"
}

verify_codex_sections() {
  local dom_file="$1"
  local projects_at
  local project_at
  local thread_at
  local project_only_at
  local chats_at
  local loose_chat_at

  projects_at="$(first_offset "Projects" "$dom_file")"
  project_at="$(first_offset_after "glasstunnel" "$dom_file" "$projects_at")"
  thread_at="$(first_offset_after "Glasstunnel 1" "$dom_file" "$project_at")"
  project_only_at="$(first_offset_after "empty-project" "$dom_file" "$thread_at")"
  chats_at="$(first_offset_after "Chats" "$dom_file" "$project_only_at")"
  loose_chat_at="$(first_offset_after "Loose chat" "$dom_file" "$chats_at")"

  if ! (( projects_at < project_at && project_at < thread_at && thread_at < project_only_at && project_only_at < chats_at && chats_at < loose_chat_at )); then
    echo "Codex project/chat fixture rendered in an unexpected order." >&2
    echo "Projects=$projects_at glasstunnel=$project_at Glasstunnel1=$thread_at emptyProject=$project_only_at Chats=$chats_at LooseChat=$loose_chat_at" >&2
    echo "DOM dump: $dom_file" >&2
    exit 1
  fi

  echo "Chrome mobile Codex project/chat DOM verified: $dom_file"
}

direct_cli_app_for_fixture() {
  case "$1" in
    workspace-codex-cli-stopped | workspace-codex-cli-starting | workspace-codex-cli-running)
      printf 'codex-cli'
      ;;
    workspace-cursor-agent-running)
      printf 'cursor-agent'
      ;;
    workspace-opencode-running)
      printf 'opencode'
      ;;
    workspace-gemini-cli-running)
      printf 'gemini-cli'
      ;;
    workspace-claude-code-running)
      printf 'claude-code'
      ;;
  esac
}

verify_running_cli_surface() {
  local fixture="$1"
  local dom_file="$2"
  local app_label="$3"
  local expected_output="$4"

  if ! grep -q "$app_label" "$dom_file" ||
    ! grep -q "Runs on your Mac. Review prompts before sending." "$dom_file" ||
    ! grep -q "Send a prompt" "$dom_file" ||
    ! grep -q "$expected_output" "$dom_file" ||
    ! grep -q "running" "$dom_file"; then
    echo "Running $app_label fixture did not render expected direct CLI command surface." >&2
    echo "DOM dump: $dom_file" >&2
    exit 1
  fi
  if grep -q "No $app_label messages yet" "$dom_file" ||
    grep -q "Once $app_label writes" "$dom_file" ||
    grep -q "Type a terminal command" "$dom_file"; then
    echo "Running $app_label fixture fell back to chat or Terminal-specific copy." >&2
    echo "DOM dump: $dom_file" >&2
    exit 1
  fi
  echo "Chrome mobile running $app_label fixture DOM verified: $dom_file"
}

verify_opencode_target_titles() {
  local dom_file="$1"
  local first_thread_at
  local second_thread_at
  local project_at

  first_thread_at="$(first_offset "Glass Tunnel 1" "$dom_file")"
  second_thread_at="$(first_offset "Glass Tunnel 2" "$dom_file")"
  project_at="$(first_offset "glasstunnel" "$dom_file")"

  if ! (( first_thread_at < second_thread_at )); then
    echo "OpenCode fixture target titles rendered in an unexpected order." >&2
    echo "GlassTunnel1=$first_thread_at GlassTunnel2=$second_thread_at project=$project_at" >&2
    echo "DOM dump: $dom_file" >&2
    exit 1
  fi

  echo "Chrome mobile OpenCode target-title DOM verified: $dom_file"
}

verify_cursor_generated_labels() {
  local dom_file="$1"
  local chats_at
  local first_chat_at
  local second_chat_at

  chats_at="$(first_offset "Chats" "$dom_file")"
  first_chat_at="$(first_offset_after "Cursor chat 1" "$dom_file" "$chats_at")"
  second_chat_at="$(first_offset_after "Cursor chat 2" "$dom_file" "$first_chat_at")"

  if ! (( chats_at < first_chat_at && first_chat_at < second_chat_at )); then
    echo "Cursor generated-label fixture rendered in an unexpected order." >&2
    echo "Chats=$chats_at CursorChat1=$first_chat_at CursorChat2=$second_chat_at" >&2
    echo "DOM dump: $dom_file" >&2
    exit 1
  fi

  echo "Chrome mobile Cursor generated-label DOM verified: $dom_file"
}

verify_cursor_agent_affordance() {
  local dom_file="$1"

  if ! grep -q "Cursor Agent" "$dom_file" ||
    ! grep -q "Ask mode only. File edits are not enabled." "$dom_file" ||
    ! grep -q "model: gpt-5.4-nano-none" "$dom_file" ||
    ! grep -q "I found one focused next fix." "$dom_file" ||
    ! grep -q "Send a prompt" "$dom_file" ||
    ! grep -q "running" "$dom_file"; then
    echo "Cursor Agent fixture did not render expected ask-mode command surface." >&2
    echo "DOM dump: $dom_file" >&2
    exit 1
  fi
  if grep -q "Attach files" "$dom_file" ||
    grep -q "Runs on your Mac. Review prompts before sending." "$dom_file" ||
    grep -q "Type a terminal command" "$dom_file"; then
    echo "Cursor Agent fixture exposed unsupported attachment or generic command-surface copy." >&2
    echo "DOM dump: $dom_file" >&2
    exit 1
  fi

  echo "Chrome mobile Cursor Agent ask-mode affordance DOM verified: $dom_file"
}

rm -f "$SERVER_LOG" "$CHROME_LOG"
pnpm --filter=@glasstunnel/mobile-pwa dev --host 127.0.0.1 --port "$PORT" --strictPort >"$SERVER_LOG" 2>&1 &
SERVER_PID="$!"

echo "==> Starting local PWA dev server"
for _ in {1..60}; do
  if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    echo "PWA dev server exited early." >&2
    cat "$SERVER_LOG" >&2
    exit 1
  fi
  sleep 1
done

if ! curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
  echo "PWA dev server did not become ready." >&2
  cat "$SERVER_LOG" >&2
  exit 1
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
for fixture in "${fixtures[@]}"; do
  screenshot="$OUT_DIR/chrome-mobile-${fixture}-${timestamp}.png"
  url="http://127.0.0.1:$PORT/?gtFixture=$fixture"
  if app_id="$(direct_cli_app_for_fixture "$fixture")" && [[ -n "$app_id" ]]; then
    url="${url}&app=$app_id"
  fi
  echo
  echo "==> Chrome mobile fixture: $fixture"
  if ! run_with_timeout "$SCREENSHOT_TIMEOUT_SECONDS" "$CHROME_BIN" \
    --headless=new \
    --disable-gpu \
    --disable-background-networking \
    --disable-component-update \
    --disable-sync \
    --disable-extensions \
    --disable-default-apps \
    --disable-crash-reporter \
    --disable-breakpad \
    --metrics-recording-only \
    --disable-features=MediaRouter,OptimizationHints,AutofillServerCommunication,CertificateTransparencyComponentUpdater \
    --hide-scrollbars \
    --log-level=3 \
    --no-first-run \
    --no-default-browser-check \
    --user-data-dir="$CHROME_PROFILE" \
    --window-size="${WIDTH},${HEIGHT}" \
    --force-device-scale-factor=2 \
    --user-agent="Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/149.0.0.0 Mobile/15E148 Safari/604.1" \
    --virtual-time-budget="$WAIT_MS" \
    --run-all-compositor-stages-before-draw \
    --screenshot="$screenshot" \
    "$url" >/dev/null 2>>"$CHROME_LOG"; then
    echo "Chrome screenshot failed or timed out for fixture '$fixture'." >&2
    echo "Chrome log: $CHROME_LOG" >&2
    exit 1
  fi
  echo "Chrome mobile QA screenshot: $screenshot"

  if [[ "$fixture" == "workspace-all-apps" ]]; then
    dom_file="$(dump_dom "$fixture" "$url")"
    verify_codex_sections "$dom_file"
  fi

  if [[ "$fixture" == "workspace-terminal-running" ]]; then
    dom_file="$(dump_dom "$fixture" "$url")"
    if ! grep -q "GT_TERMINAL_STREAM" "$dom_file" ||
      ! grep -q "Default Terminal" "$dom_file" ||
      ! grep -q "Terminal 2" "$dom_file" ||
      ! grep -q "Switch session" "$dom_file" ||
      ! grep -q "Rename" "$dom_file" ||
      ! grep -q "Close" "$dom_file" ||
      ! grep -q "Runs on your Mac. Review commands before running." "$dom_file" ||
      ! grep -q "running" "$dom_file"; then
      echo "Terminal fixture did not render expected session label, controls, command/output/running state." >&2
      echo "DOM dump: $dom_file" >&2
      exit 1
    fi
    echo "Chrome mobile Terminal fixture DOM verified: $dom_file"
  fi

  if [[ "$fixture" == "workspace-terminal-stopped" ]]; then
    dom_file="$(dump_dom "$fixture" "$url")"
    if ! grep -q "Terminal is ready" "$dom_file" ||
      ! grep -q "Open Terminal on this Mac." "$dom_file" ||
      ! grep -q "Open Terminal" "$dom_file"; then
      echo "Terminal stopped fixture did not render expected open action state." >&2
      echo "DOM dump: $dom_file" >&2
      exit 1
    fi
    if grep -q "Type a terminal command" "$dom_file"; then
      echo "Terminal stopped fixture exposed the command composer before start." >&2
      echo "DOM dump: $dom_file" >&2
      exit 1
    fi
    echo "Chrome mobile stopped Terminal fixture DOM verified: $dom_file"
  fi

  if [[ "$fixture" == "workspace-codex-cli-stopped" ]]; then
    dom_file="$(dump_dom "$fixture" "$url")"
    if ! grep -q "Codex CLI stopped" "$dom_file" ||
      ! grep -q "Start Codex CLI on this Mac." "$dom_file" ||
      ! grep -q "Start" "$dom_file"; then
      echo "Stopped Codex CLI fixture did not render expected Start recovery state." >&2
      echo "DOM dump: $dom_file" >&2
      exit 1
    fi
    if grep -q "Type a terminal command" "$dom_file" ||
      grep -q "Mac offline" "$dom_file"; then
      echo "Stopped Codex CLI fixture exposed stale command input or offline copy." >&2
      echo "DOM dump: $dom_file" >&2
      exit 1
    fi
    echo "Chrome mobile stopped Codex CLI fixture DOM verified: $dom_file"
  fi

  if [[ "$fixture" == "workspace-codex-cli-starting" ]]; then
    dom_file="$(dump_dom "$fixture" "$url")"
    if ! grep -q "Codex CLI did not respond" "$dom_file" ||
      ! grep -q "Try again or open it on the Mac." "$dom_file" ||
      ! grep -q "Retry" "$dom_file"; then
      echo "Starting Codex CLI fixture did not render expected retry timeout state." >&2
      echo "DOM dump: $dom_file" >&2
      exit 1
    fi
    if grep -q "Send a prompt" "$dom_file" ||
      grep -q "Starting Codex CLI inside Glasstunnel" "$dom_file"; then
      echo "Starting Codex CLI fixture exposed stale command input or starting log." >&2
      echo "DOM dump: $dom_file" >&2
      exit 1
    fi
    echo "Chrome mobile starting Codex CLI fixture DOM verified: $dom_file"
  fi

  if [[ "$fixture" == "workspace-codex-cli-running" ]]; then
    dom_file="$(dump_dom "$fixture" "$url")"
    verify_running_cli_surface "$fixture" "$dom_file" "Codex CLI" "model: gpt-5.5 xhigh"
  fi

  if [[ "$fixture" == "workspace-codex-target-unverified" ]]; then
    dom_file="$(dump_dom "$fixture" "$url")"
    if ! grep -q "Open chat: Glasstunnel 1" "$dom_file" ||
      ! grep -q "Open this chat" "$dom_file" ||
      ! grep -q 'placeholder="Send a prompt\.\.\."' "$dom_file" ||
      ! grep -q 'placeholder="Send a prompt\.\.\."[^>]*disabled' "$dom_file"; then
      echo "Unverified Codex target fixture did not render retryable target and disabled composer." >&2
      echo "DOM dump: $dom_file" >&2
      exit 1
    fi
    echo "Chrome mobile unverified Codex target DOM verified: $dom_file"
  fi

  if [[ "$fixture" == "workspace-cursor-generated-labels" ]]; then
    dom_file="$(dump_dom "$fixture" "$url")"
    verify_cursor_generated_labels "$dom_file"
  fi

  if [[ "$fixture" == "workspace-cursor-agent-running" ]]; then
    dom_file="$(dump_dom "$fixture" "$url")"
    verify_cursor_agent_affordance "$dom_file"
  fi

  if [[ "$fixture" == "workspace-opencode-running" ]]; then
    dom_file="$(dump_dom "$fixture" "$url")"
    verify_running_cli_surface "$fixture" "$dom_file" "OpenCode" "provider/model: opencode/nemotron-3-ultra-free"
    verify_opencode_target_titles "$dom_file"
  fi

  if [[ "$fixture" == "workspace-gemini-cli-running" ]]; then
    dom_file="$(dump_dom "$fixture" "$url")"
    verify_running_cli_surface "$fixture" "$dom_file" "Gemini CLI" "model: gemini-2.5-pro"
  fi

  if [[ "$fixture" == "workspace-claude-code-running" ]]; then
    dom_file="$(dump_dom "$fixture" "$url")"
    verify_running_cli_surface "$fixture" "$dom_file" "Claude Code" "model: sonnet"
  fi
done

echo
echo "Result: passed; local Chrome mobile screenshots captured for ${fixtures[*]} fixtures."
echo "This is headless Chrome fixture evidence. Physical-phone evidence is optional unless an explicit hardware gate requires it."
