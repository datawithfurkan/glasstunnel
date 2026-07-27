#!/usr/bin/env bash
# Recommend or run validation commands for the current Glasstunnel diff.
#
# Default mode prints commands. Use --run to execute them.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN=false
ALL=false

usage() {
  cat <<'USAGE'
Usage: bash scripts/agent-validate.sh [--run] [--all]

Options:
  --run   Execute the recommended commands.
  --all   Recommend broad repo checks even when there is no local diff.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      RUN=true
      ;;
    --all)
      ALL=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

cd "$ROOT_DIR"

declare -a files=()
if [[ "$ALL" == true ]]; then
  files=()
else
  while IFS= read -r file; do
    files+=("$file")
  done < <(
    {
      git diff --name-only
      git diff --name-only --cached
      git ls-files --others --exclude-standard
    } | awk 'NF' | sort -u
  )
fi

declare -a labels=()
declare -a commands=()
declare -a notes=()

has_command() {
  local needle="$1"
  local command
  if [[ ${#commands[@]} -eq 0 ]]; then
    return 1
  fi
  for command in "${commands[@]}"; do
    [[ "$command" == "$needle" ]] && return 0
  done
  return 1
}

add_cmd() {
  local label="$1"
  local command="$2"
  if has_command "$command"; then
    return
  fi
  labels+=("$label")
  commands+=("$command")
}

add_note() {
  notes+=("$1")
}

has_file() {
  local pattern="$1"
  local file
  if [[ ${#files[@]} -eq 0 ]]; then
    return 1
  fi
  for file in "${files[@]}"; do
    [[ "$file" == $pattern ]] && return 0
  done
  return 1
}

add_cmd "Diff whitespace check" "git diff --check"

if [[ "$ALL" == true ]]; then
  echo "All-surfaces mode enabled."
  echo
elif [[ ${#files[@]} -eq 0 ]]; then
  echo "No local file changes detected."
  echo "Use --all to print broad repo validation commands."
  echo
fi

if [[ "$ALL" == true ]]; then
  add_cmd "Local lab unit tests" "pnpm lab:test:unit"
  add_cmd "Cloudflare Worker typecheck" "pnpm worker:typecheck"
  add_cmd "Cloudflare Worker runtime tests" "pnpm worker:test"
  add_cmd "Cloudflare Worker dry-run build" "pnpm worker:build"
  add_cmd "Protocol codegen check" "bash scripts/protocol-codegen-check.sh"
  add_cmd "Protocol package build" "pnpm --filter=@glasstunnel/protocol build"
  add_cmd "Full JS build" "pnpm build"
  add_cmd "Full JS tests" "pnpm test"
  add_cmd "Full JS lint/typecheck" "pnpm lint"
  add_cmd "Go signaling" "cd apps/signaling && go build ./... && go vet ./... && go test ./..."
  add_cmd "Mac host tests" "swift test --package-path apps/host-macos"
fi

if has_file "apps/mobile-pwa/*" || has_file "apps/mobile-pwa/**"; then
  add_cmd "Mobile PWA lint" "pnpm --filter=@glasstunnel/mobile-pwa lint"
  add_cmd "Mobile PWA tests" "pnpm --filter=@glasstunnel/mobile-pwa test"
  add_cmd "Mobile PWA build" "pnpm --filter=@glasstunnel/mobile-pwa build"
  add_note "If UI changed, verify in a browser/mobile viewport and capture the final visible state."
fi

if has_file "site/*" || has_file "site/**"; then
  add_cmd "Site build" "pnpm --filter=@glasstunnel/site build"
fi

if has_file "packages/shared-crypto/*" || has_file "packages/shared-crypto/**"; then
  add_cmd "Shared crypto build" "pnpm --filter=@glasstunnel/shared-crypto build"
  add_cmd "Shared crypto tests" "pnpm --filter=@glasstunnel/shared-crypto test"
fi

if has_file "packages/protocol/*" || has_file "packages/protocol/**"; then
  add_cmd "Protocol codegen check" "bash scripts/protocol-codegen-check.sh"
  add_cmd "Protocol package build" "pnpm --filter=@glasstunnel/protocol build"
  add_cmd "Mac protocol tests" "swift test --package-path apps/host-macos --filter GTProtocolTests"
  add_note "Protocol changes often require matching Mac and web UI/state updates under docs/agent-ui-contract.md."
fi

if has_file "apps/host-macos/*" || has_file "apps/host-macos/**"; then
  add_cmd "Mac host tests" "swift test --package-path apps/host-macos"
  add_note "If permission, signing, menu bar, or onboarding behavior changed, test a bundled app launch when possible."
fi

if has_file "apps/signaling/*" || has_file "apps/signaling/**"; then
  add_cmd "Go signaling" "cd apps/signaling && go build ./... && go vet ./... && go test ./..."
fi

if has_file "apps/cloudflare-signal/*" || has_file "apps/cloudflare-signal/**"; then
  add_cmd "Cloudflare Worker typecheck" "pnpm worker:typecheck"
  add_cmd "Cloudflare Worker runtime tests" "pnpm worker:test"
  add_cmd "Cloudflare Worker dry-run build" "pnpm worker:build"
fi

if has_file "package.json" || has_file "pnpm-lock.yaml" || has_file "pnpm-workspace.yaml" || has_file "tsconfig*.json"; then
  add_cmd "Workspace build" "pnpm build"
  add_cmd "Workspace tests" "pnpm test"
  add_cmd "Workspace lint/typecheck" "pnpm lint"
fi

if has_file ".github/*" || has_file ".github/**"; then
  add_note "Workflow changes should be checked in GitHub Actions after push."
fi

if has_file "scripts/*.sh" || has_file "scripts/**"; then
  add_cmd "Shell script syntax" "find scripts -maxdepth 1 -name '*.sh' -print0 | xargs -0 -n1 bash -n"
fi

if has_file "scripts/lab/*" || has_file "scripts/lab/**" || has_file "playwright.config.ts" || has_file "tests/e2e/*" || has_file "tests/e2e/**"; then
  add_cmd "Local lab unit tests" "pnpm lab:test:unit"
fi

if has_file "playwright.config.ts" || has_file "tests/e2e/*" || has_file "tests/e2e/**"; then
  add_cmd "Local browser integration" "pnpm lab:e2e"
  add_note "Playwright owns and cleans its local lab run; failure artifacts stay under .cache/glasstunnel-lab/playwright/."
fi

if has_file "supabase/*" || has_file "supabase/**"; then
  add_note "Supabase migration/config changes need a local Supabase validation or a clear note if not run."
fi

echo "Changed files considered:"
if [[ "$ALL" == true ]]; then
  echo "  (all-surfaces broad checks)"
elif [[ ${#files[@]} -eq 0 ]]; then
  echo "  (none)"
else
  printf '  %s\n' "${files[@]}"
fi

echo
echo "Recommended validation:"
for i in "${!commands[@]}"; do
  printf '  %d. %s\n     %s\n' "$((i + 1))" "${labels[$i]}" "${commands[$i]}"
done

if [[ ${#notes[@]} -gt 0 ]]; then
  echo
  echo "Manual notes:"
  printf '  - %s\n' "${notes[@]}"
fi

if [[ "$RUN" != true ]]; then
  exit 0
fi

echo
echo "Running validation..."
for i in "${!commands[@]}"; do
  echo
  echo "==> ${labels[$i]}"
  bash -lc "${commands[$i]}"
done
