#!/usr/bin/env bash
# Report the latest GitHub CI/deploy state for the current commit.
#
# Default mode is informational and exits 0 so local release-readiness can still
# run when GitHub is unavailable. Use --strict for a release gate.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRICT=0
BRANCH="${GT_GITHUB_RELEASE_BRANCH:-main}"
REMOTE="${GT_GITHUB_RELEASE_REMOTE:-origin}"
REPO="${GT_GITHUB_RELEASE_REPO:-}"

usage() {
  cat <<'USAGE'
Usage: bash scripts/github-release-state.sh [--strict]

Reports the latest GitHub CI and Deploy workflow runs for the current commit.

Options:
  --strict  Exit nonzero unless both CI and Deploy are completed successfully.

Environment:
  GT_GITHUB_RELEASE_BRANCH  Branch to inspect, default: main
  GT_GITHUB_RELEASE_REMOTE  Git remote used to infer owner/repo, default: origin
  GT_GITHUB_RELEASE_REPO    Explicit GitHub repo in owner/name form.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict)
      STRICT=1
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

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub release state: gh CLI is not installed."
  [[ "$STRICT" == "1" ]] && exit 1
  exit 0
fi

if [[ -z "$REPO" ]]; then
  remote_url="$(git remote get-url "$REMOTE" 2>/dev/null || true)"
  case "$remote_url" in
    git@github.com:*)
      REPO="${remote_url#git@github.com:}"
      REPO="${REPO%.git}"
      ;;
    https://github.com/*)
      REPO="${remote_url#https://github.com/}"
      REPO="${REPO%.git}"
      ;;
  esac
fi

if [[ -z "$REPO" ]]; then
  echo "GitHub release state: could not infer owner/repo from remote '$REMOTE'."
  [[ "$STRICT" == "1" ]] && exit 1
  exit 0
fi

commit="$(git rev-parse HEAD)"
short_commit="$(git rev-parse --short HEAD)"

echo "Glasstunnel GitHub release state"
echo "Repo: $REPO"
echo "Branch: $BRANCH"
echo "Commit: $short_commit $(git log -1 --pretty=%s)"
echo

run_field() {
  local workflow="$1"
  local field="$2"
  gh run list \
    --repo "$REPO" \
    --branch "$BRANCH" \
    --limit 30 \
    --json databaseId,workflowName,headSha,status,conclusion,event,createdAt,url \
    --jq "first(.[] | select(.workflowName == \"$workflow\" and .headSha == \"$commit\")) | .$field"
}

print_annotations() {
  local run_id="$1"
  local failed_jobs
  failed_jobs="$(gh run view "$run_id" --repo "$REPO" --json jobs --jq '.jobs[] | select(.conclusion == "failure") | .databaseId' 2>/dev/null || true)"
  if [[ -z "$failed_jobs" ]]; then
    return
  fi

  while IFS= read -r job_id; do
    [[ -z "$job_id" ]] && continue
    gh api "repos/$REPO/check-runs/$job_id/annotations" \
      --jq '.[] | "- " + .message' 2>/dev/null || true
  done <<< "$failed_jobs"
}

status_for_workflow() {
  local workflow="$1"
  local id status conclusion event url created
  id="$(run_field "$workflow" databaseId 2>/dev/null || true)"
  status="$(run_field "$workflow" status 2>/dev/null || true)"
  conclusion="$(run_field "$workflow" conclusion 2>/dev/null || true)"
  event="$(run_field "$workflow" event 2>/dev/null || true)"
  url="$(run_field "$workflow" url 2>/dev/null || true)"
  created="$(run_field "$workflow" createdAt 2>/dev/null || true)"

  if [[ -z "$id" || "$id" == "null" ]]; then
    echo "$workflow: missing for $short_commit"
    return 1
  fi

  echo "$workflow: $status/${conclusion:-none} ($event, $created)"
  echo "  $url"

  if [[ "$status" != "completed" || "$conclusion" != "success" ]]; then
    annotations="$(print_annotations "$id")"
    if [[ -n "$annotations" ]]; then
      echo "  annotations:"
      printf '%s\n' "$annotations" | sed 's/^/  /'
    fi
    return 1
  fi

  return 0
}

failures=0
status_for_workflow "CI" || failures=$((failures + 1))
status_for_workflow "Deploy" || failures=$((failures + 1))

echo
if [[ "$failures" -eq 0 ]]; then
  echo "Result: GitHub CI and Deploy are green for $short_commit."
else
  echo "Result: $failures GitHub release workflow(s) are not green for $short_commit."
fi

if [[ "$STRICT" == "1" && "$failures" -ne 0 ]]; then
  exit 1
fi
