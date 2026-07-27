#!/usr/bin/env bash
# Run the hosted Terminal relay diagnostic using the local disposable smoke account.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:terminal:live:smoke-account

Loads .env.platform.local and .env.smoke.local, exchanges the disposable smoke
account credentials for a short-lived Supabase access token, then runs
pnpm qa:terminal:live without printing the token.

Required local-only env values:
  .env.platform.local: SUPABASE_URL, SUPABASE_ANON_KEY
  .env.smoke.local:    SMOKE_EMAIL, SMOKE_PASSWORD

Optional:
  GT_TERMINAL_LIVE_HOST_DEVICE_ID
  GT_TERMINAL_LIVE_SIGNALING_URL
  GT_TERMINAL_LIVE_ARTIFACT_DIR
  GT_TERMINAL_LIVE_TIMEOUT_MS
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

if (!url || !anon || !email || !password) {
  console.error('missing smoke account environment');
  process.exit(2);
}

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

GT_TERMINAL_LIVE_ACCESS_TOKEN="$access_token" pnpm qa:terminal:live
