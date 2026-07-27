#!/usr/bin/env bash
# Privacy-safe automated screen-sharing state regression smoke.
#
# This does not start a live screen capture or connect to a phone. It runs the
# Mac and mobile tests that guard stale screen state, stop confirmation, relay
# frame freshness, video-peer cleanup, quality feedback, and screen-specific copy.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

echo "Glasstunnel screen state smoke"
echo "Date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "Commit: $(git rev-parse --short HEAD 2>/dev/null || printf unknown)"
echo

echo "==> Mac Screen remote-app state"
swift test --package-path apps/host-macos --filter RemoteAppControllerTests
swift test --package-path apps/host-macos --filter AsyncLatestStateReconcilerTests
echo

echo "==> Mobile screen state and copy"
pnpm --filter=@glasstunnel/mobile-pwa test -- \
  src/lib/remoteApps.test.ts \
  src/lib/store.test.ts \
  src/transport/PeerFlowAbortRegistry.test.ts \
  src/transport/startPeerFlow.test.ts \
  src/agents/screenVideoStatus.test.ts \
  src/agents/ScreenRemotePanel.pointer.test.ts \
  src/agents/ScreenRemotePanel.test.ts \
  src/lib/connectionCopy.test.ts
echo

echo "Result: passed; automated screen state checks covered serialized capture transitions, superseded peer cleanup, start/off/restart snapshots, stale stopping snapshots, stale and far-future relay-frame rejection, render-gated control, stop confirmation copy, video-peer cleanup, and quality-change feedback."
echo "This is not live-capture evidence. Local Chromium/WebKit and signed Mac start/stop/restart verification remains required before public release."
