#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env.platform.local"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a

: "${SUPABASE_URL:?SUPABASE_URL is required in .env.platform.local}"
: "${SUPABASE_ANON_KEY:?SUPABASE_ANON_KEY is required in .env.platform.local}"

export VITE_PUBLIC_APP_URL="${VITE_PUBLIC_APP_URL:-https://app.glasstunnel.io}"
export VITE_SIGNALING_URL="${VITE_SIGNALING_URL:-wss://signaling.glasstunnel.io/signal}"
export VITE_SUPABASE_URL="${SUPABASE_URL}"
export VITE_SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY}"

PROJECT_NAME="${CLOUDFLARE_PAGES_PROJECT:-glasstunnel}"
BRANCH_NAME="${1:-main}"

cd "${ROOT_DIR}"

pnpm --filter=@glasstunnel/protocol build
pnpm --filter=@glasstunnel/shared-crypto build
pnpm --filter=@glasstunnel/mobile-pwa build
pnpm dlx wrangler@4 pages deploy apps/mobile-pwa/dist --project-name "${PROJECT_NAME}" --branch "${BRANCH_NAME}"
