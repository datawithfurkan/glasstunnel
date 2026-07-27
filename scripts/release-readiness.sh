#!/usr/bin/env bash
# Run broad release-readiness checks for Glasstunnel.
#
# Default: local automated checks only.
# Optional: set GT_RELEASE_READINESS_MOBILE=1 or pass --mobile to run local
# mobile fixture smokes and iOS Simulator auth smoke.
# Optional: set GT_RELEASE_READINESS_PHYSICAL=1 to require physical-phone
# evidence for a release gate that explicitly needs device hardware coverage.
# Optional: set GT_RELEASE_READINESS_GITHUB=1 or pass --github to require green
# GitHub CI and Deploy for the current commit after pushing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_MOBILE="${GT_RELEASE_READINESS_MOBILE:-0}"
RUN_PHYSICAL="${GT_RELEASE_READINESS_PHYSICAL:-0}"
RUN_GITHUB="${GT_RELEASE_READINESS_GITHUB:-0}"

usage() {
  cat <<'USAGE'
Usage: bash scripts/release-readiness.sh [--mobile] [--no-mobile] [--github] [--no-github]

Runs broad local checks:
  - protocol codegen dirty-tree guard
  - workspace build/test/lint
  - Go signaling build/vet/test
  - Swift Mac host tests
  - Mac permission/onboarding audit
  - Mac app lifecycle truthfulness audit
  - Mac live evidence recorder smoke
  - Mac distribution docs/script alignment audit
  - Homebrew cask update smoke
  - security/privacy release audit
  - Mac DMG install/upgrade smoke when a DMG artifact exists
  - screen-sharing state smoke
  - agent-app release audit
  - mobile evidence recorder smoke
  - release goal-loop process log check

Options:
  --mobile     Also run mobile fixture smokes and pnpm qa:mobile:ios.
  --no-mobile  Skip mobile simulator smoke even if GT_RELEASE_READINESS_MOBILE=1.
  --github     Require GitHub CI and Deploy to be green for the current commit.
  --no-github  Skip GitHub release-state strict check even if GT_RELEASE_READINESS_GITHUB=1.

Environment:
  GT_RELEASE_READINESS_MOBILE=1  Run mobile fixture smokes and iOS Simulator smoke.
  GT_RELEASE_READINESS_PHYSICAL=1 Require recorded physical-phone evidence for an explicit hardware gate.
  GT_RELEASE_READINESS_GITHUB=1  Require green GitHub CI and Deploy for the current commit.
  GT_MOBILE_QA_URL=...           Override mobile smoke URL.
  GT_MOBILE_QA_DEVICE=...        Override simulator device.
  GT_MOBILE_QA_WAIT=...          Override screenshot wait.
  GT_MOBILE_QA_SIMCTL_TIMEOUT=... Override simulator command timeout; qa:mobile:ios defaults to 60s.
  GT_REAL_MOBILE_REQUIRED_BROWSERS Override physical-phone evidence browsers.
  GT_REAL_MOBILE_REQUIRED_SCOPES   Override physical-phone evidence scopes.
  GT_GITHUB_RELEASE_REPO           Override GitHub repo used by the release-state check.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --)
      ;;
    --mobile)
      RUN_MOBILE=1
      ;;
    --no-mobile)
      RUN_MOBILE=0
      ;;
    --github)
      RUN_GITHUB=1
      ;;
    --no-github)
      RUN_GITHUB=0
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

echo "Glasstunnel release readiness"
echo "Repo: $ROOT_DIR"
echo "Commit: $(git rev-parse --short HEAD) $(git log -1 --pretty=%s)"
echo "Branch: $(git branch --show-current)"
echo

echo "==> Working tree"
git status --short --branch
echo

echo "==> Broad automated checks"
bash scripts/agent-validate.sh --all --run

echo
echo "==> Mac permission/onboarding audit"
pnpm qa:mac-permission-onboarding

echo
echo "==> Mac app lifecycle truthfulness audit"
pnpm qa:mac-lifecycle

echo
echo "==> Mac live evidence recorder smoke"
pnpm qa:mac:live:record-smoke

echo
echo "==> Mac distribution docs/script alignment audit"
pnpm qa:mac:distribution-docs

echo
echo "==> Homebrew cask audit and update smoke"
pnpm qa:mac:cask-audit
pnpm qa:mac:cask-update

echo
echo "==> Mac notarization contract smoke"
pnpm qa:mac:notarization

echo
echo "==> Security/privacy release audit"
pnpm qa:security-privacy

echo
echo "==> Mac install/reinstall artifact smoke"
if compgen -G "$ROOT_DIR/dist/Glasstunnel-*.dmg" >/dev/null; then
  pnpm release:mac:install-smoke
  echo
  echo "==> Local Homebrew cask install smoke"
  pnpm qa:mac:cask-install
else
  echo "Skipping Mac install/reinstall smoke because no dist/Glasstunnel-*.dmg artifact exists."
  echo "Skipping local Homebrew cask install smoke for the same reason."
  echo "Build one first with: ./scripts/build-app.sh --local-sign 0.1.0"
fi

echo
echo "==> Screen-sharing state smoke"
pnpm qa:screen-state

echo
echo "==> Agent-app release audit"
bash scripts/release-agent-apps.sh

echo
echo "==> Mobile evidence recorder smoke"
pnpm qa:mobile:real:record-smoke

echo
echo "==> Release goal-loop process log"
pnpm qa:goal-loop-log

if [[ "$RUN_MOBILE" == "1" ]]; then
  echo
  echo "==> Mobile Safari workspace fixture smoke"
  pnpm qa:mobile:workspace-fixture

  echo
  echo "==> Mobile Chrome workspace fixture smoke"
  pnpm qa:mobile:chrome-fixture

  echo
  echo "==> iOS mobile smoke"
  pnpm qa:mobile:ios

  if [[ "$RUN_PHYSICAL" == "1" ]]; then
    echo
    echo "==> Physical-phone mobile evidence"
    bash scripts/check-real-mobile-evidence.sh
  else
    echo
    echo "Skipping optional physical-phone evidence."
    echo "Set GT_RELEASE_READINESS_PHYSICAL=1 only for an explicitly named hardware gate."
  fi
else
  echo
  echo "Skipping iOS mobile smoke."
  echo "Run with --mobile or GT_RELEASE_READINESS_MOBILE=1 when a mobile UI/browser pass is needed."
  echo "Physical-phone evidence is optional unless an explicit hardware gate requires it."
fi

if [[ "$RUN_GITHUB" == "1" ]]; then
  echo
  echo "==> GitHub release state"
  bash scripts/github-release-state.sh --strict
else
  echo
  echo "Skipping GitHub release-state strict check."
  echo "Run with --github or GT_RELEASE_READINESS_GITHUB=1 after pushing a release candidate."
fi

echo
echo "Manual release gates still required before public release:"
echo "  - Fresh Mac app permission onboarding on a real bundled app."
echo "  - Real-app verification rows in docs/agent-app-support-matrix.md."
echo "  - Signing, notarization, DMG, and reinstall/upgrade verification."
echo
echo "Release readiness checks completed."
