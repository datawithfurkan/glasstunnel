#!/usr/bin/env bash
# Run the automated Mac permission/onboarding release diagnostics.
#
# This command does not launch Glasstunnel, reset TCC permissions, open System
# Settings, contact Apple notarization services, or intentionally trigger
# keychain prompts. It verifies the code and packaged-artifact prerequisites
# that can be proven before a live bundled-app permission pass.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

run_check() {
  local label="$1"
  shift

  echo "==> $label"
  "$@"
  echo
}

echo "Glasstunnel Mac permission/onboarding audit"
echo "Repo: $ROOT_DIR"
echo "Commit: $(git rev-parse --short HEAD 2>/dev/null || printf unknown) $(git log -1 --pretty=%s 2>/dev/null || true)"
echo

run_check "Mac release identity and entitlement preflight" pnpm release:mac:preflight
run_check "Permission source-of-truth tests" swift test --package-path apps/host-macos --filter PermissionsTests
run_check "Permission onboarding gate tests" swift test --package-path apps/host-macos --filter PermissionOnboardingGateTests
run_check "First-run onboarding content policy tests" swift test --package-path apps/host-macos --filter OnboardingContentPolicyTests
run_check "Post-permission account route tests" swift test --package-path apps/host-macos --filter AccountRoutePolicyTests
run_check "Linked-account relaunch cache tests" swift test --package-path apps/host-macos --filter AccountLinkControllerTests

echo "Result: passed; automated Mac permission/onboarding diagnostics verified stable bundle identity, release entitlements, permission source-of-truth policy, intro-before-permissions routing, Continue-to-auth gating, account-route decisions, and linked-account cache behavior."
echo "This is not live bundled-app TCC evidence. Fresh install, already-granted permissions, removed permissions, System Settings return, and signed-in relaunch persistence still require a manual app run before public release."
