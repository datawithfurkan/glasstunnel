#!/usr/bin/env bash
# Capture local mobile workspace fixture screenshots in iOS Safari.
#
# This is local visual QA only. It does not require a signed-in account, live
# Mac app or real phone. Hardware evidence remains separate when a named gate
# explicitly requires it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${GT_MOBILE_FIXTURE_PORT:-5175}"
WAIT_SECONDS="${GT_MOBILE_FIXTURE_WAIT:-3}"
SERVER_LOG="${TMPDIR:-/tmp}/glasstunnel-mobile-workspace-fixture-vite.log"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

cd "$ROOT_DIR"

echo "Glasstunnel mobile workspace fixture smoke"
echo "Repo: $ROOT_DIR"
echo "Commit: $(git rev-parse --short HEAD 2>/dev/null || printf unknown)"
echo "Port: $PORT"
echo

rm -f "$SERVER_LOG"
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
  workspace-offline-cached
)

for fixture in "${fixtures[@]}"; do
  echo
  echo "==> iOS Safari fixture: $fixture"
  GT_MOBILE_QA_URL="http://127.0.0.1:$PORT/?gtFixture=$fixture" \
    GT_MOBILE_QA_WAIT="$WAIT_SECONDS" \
    pnpm qa:mobile:ios
done

echo
echo "Result: passed; local iOS Safari screenshots captured for ${fixtures[*]} fixtures."
echo "This is simulator evidence. Physical-phone evidence is optional unless an explicit hardware gate requires it."
