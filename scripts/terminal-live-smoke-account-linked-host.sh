#!/usr/bin/env bash
# Run the hosted Terminal relay diagnostic with a local disposable host harness.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:terminal:live:linked-smoke-account

Loads .env.platform.local and .env.smoke.local, obtains a short-lived smoke
account token, starts an isolated local Mac host harness, claims its link code
to the smoke account, then runs the hosted Terminal relay diagnostic.

This is hosted relay evidence only. It is not rendered Safari/Chrome UI or
physical-phone evidence.
USAGE
}

if [[ "${1:-}" == "--" ]]; then
  shift
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

for file in .env.platform.local .env.smoke.local; do
  if [[ ! -f "$file" ]]; then
    echo "Missing $file. See usage for required local smoke credentials." >&2
    exit 2
  fi
done

set -a
# shellcheck disable=SC1091
source .env.platform.local
# shellcheck disable=SC1091
source .env.smoke.local
set +a

: "${SUPABASE_URL:?SUPABASE_URL is required in .env.platform.local}"
: "${SUPABASE_ANON_KEY:?SUPABASE_ANON_KEY is required in .env.platform.local}"
: "${SMOKE_EMAIL:?SMOKE_EMAIL is required in .env.smoke.local}"
: "${SMOKE_PASSWORD:?SMOKE_PASSWORD is required in .env.smoke.local}"

access_token="$(
  node <<'NODE'
const url = process.env.SUPABASE_URL;
const anon = process.env.SUPABASE_ANON_KEY;
const email = process.env.SMOKE_EMAIL;
const password = process.env.SMOKE_PASSWORD;

const response = await fetch(`${url.replace(/\/+$/, '')}/auth/v1/token?grant_type=password`, {
  method: 'POST',
  headers: {
    apikey: anon,
    authorization: `Bearer ${anon}`,
    'content-type': 'application/json',
  },
  body: JSON.stringify({ email, password }),
});

const payload = await response.json().catch(() => ({}));
if (!response.ok || !payload.access_token) {
  const reason = payload.error_description || payload.msg || payload.error || 'unknown error';
  console.error(`smoke account auth failed with ${response.status}: ${reason}`);
  process.exit(1);
}

process.stdout.write(payload.access_token);
NODE
)"

host_log="$(mktemp -t glasstunnel-terminal-host.XXXXXX.log)"
host_pid=""
cleanup() {
  if [[ -n "$host_pid" ]] && kill -0 "$host_pid" 2>/dev/null; then
    kill "$host_pid" 2>/dev/null || true
    wait "$host_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

GLASSTUNNEL_DEV=1 \
GLASSTUNNEL_KEYCHAIN_SUFFIX="${GT_TERMINAL_LIVE_KEY_SUFFIX:-terminal-live-smoke}" \
GT_TERMINAL_LIVE_HOST_SECONDS="${GT_TERMINAL_LIVE_HOST_SECONDS:-120}" \
swift run --package-path apps/host-macos TerminalLiveHostHarness >"$host_log" 2>&1 &
host_pid="$!"

host_device_id=""
link_code=""
deadline=$((SECONDS + 45))
while (( SECONDS < deadline )); do
  if ! kill -0 "$host_pid" 2>/dev/null; then
    echo "Terminal live host harness exited before link code." >&2
    sed -E 's/(token|password|secret|key)=([^[:space:]]+)/\1=<redacted>/Ig' "$host_log" >&2 || true
    exit 1
  fi
  host_device_id="$(awk '/^HOST_DEVICE_ID / { print $2; exit }' "$host_log")"
  link_code="$(awk '/^LINK_CODE / { print $2; exit }' "$host_log")"
  if [[ -n "$host_device_id" && -n "$link_code" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$host_device_id" || -z "$link_code" ]]; then
  echo "Timed out waiting for Terminal live host link code." >&2
  sed -E 's/(token|password|secret|key)=([^[:space:]]+)/\1=<redacted>/Ig' "$host_log" >&2 || true
  exit 1
fi

GT_SMOKE_ACCESS_TOKEN="$access_token" \
GT_SMOKE_LINK_CODE="$link_code" \
node <<'NODE'
const token = process.env.GT_SMOKE_ACCESS_TOKEN;
const code = process.env.GT_SMOKE_LINK_CODE;
const signaling = process.env.GT_TERMINAL_LIVE_SIGNALING_URL || 'wss://signaling.glasstunnel.io/signal';
const apiBase = signaling.replace(/^ws/i, 'http').replace(/\/signal\/?$/, '');

const response = await fetch(`${apiBase}/account/claim-host-code`, {
  method: 'POST',
  headers: {
    authorization: `Bearer ${token}`,
    'content-type': 'application/json',
  },
  body: JSON.stringify({ code }),
});
const payload = await response.json().catch(() => ({}));
if (!response.ok) {
  const reason = payload.error || payload.msg || 'unknown error';
  console.error(`claim host code failed with ${response.status}: ${reason}`);
  process.exit(1);
}
NODE

GT_TERMINAL_LIVE_ACCESS_TOKEN="$access_token" \
GT_TERMINAL_LIVE_HOST_DEVICE_ID="$host_device_id" \
pnpm qa:terminal:live
