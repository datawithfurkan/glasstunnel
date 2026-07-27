#!/usr/bin/env bash
# Verify Mac-published app availability and lifecycle states without launching
# user apps, touching TCC, or requiring a signed-in mobile session.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

echo "Glasstunnel Mac app lifecycle truthfulness audit"
echo "Repo: $ROOT_DIR"
echo "Commit: $(git rev-parse --short HEAD) $(git log -1 --pretty=%s)"
echo "Branch: $(git branch --show-current)"
echo

echo "==> Local app availability"
pnpm qa:local-apps
echo

echo "==> Mac remote-app lifecycle states"
swift test --package-path apps/host-macos --filter RemoteAppControllerTests
echo

echo "==> Mobile remote-app lifecycle UI"
pnpm --filter @glasstunnel/mobile-pwa test -- \
  src/agents/AgentCarousel.test.tsx \
  src/lib/remoteApps.test.ts
echo

echo "Result: passed; local app publication, missing-app truthfulness, Mac pending/error snapshots, and mobile retry/error state models were verified."
echo "This is not signed-in mobile or live app-launch evidence. Real Cursor/Codex GUI launch, hosted mobile app actions, and account-linked relaunch behavior still require manual release verification."
