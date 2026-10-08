#!/usr/bin/env bash
# Run the hosted Terminal relay diagnostic using the local disposable smoke account.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:terminal:live:smoke-account

Loads .env.smoke.local (and .env.platform.local when present), signs the
disposable smoke account in to get a Glasstunnel session token, then runs
pnpm qa:terminal:live without printing the token.

Required local-only env values:
  .env.smoke.local:    SMOKE_EMAIL, SMOKE_PASSWORD

Optional:
  CONVEX_SITE_URL (auth server; defaults to production)
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

for file in .env.smoke.local; do
  if [[ ! -f "$file" ]]; then
    echo "Missing $file. See usage for required local smoke credentials." >&2
    exit 2
  fi
done

set -a
# shellcheck disable=SC1091
[[ -f .env.platform.local ]] && source .env.platform.local
# shellcheck disable=SC1091
source .env.smoke.local
set +a

: "${SMOKE_EMAIL:?SMOKE_EMAIL is required in .env.smoke.local}"
: "${SMOKE_PASSWORD:?SMOKE_PASSWORD is required in .env.smoke.local}"

access_token="$(node "$ROOT_DIR/scripts/smoke-account-token.mjs")"

GT_TERMINAL_LIVE_ACCESS_TOKEN="$access_token" pnpm qa:terminal:live
