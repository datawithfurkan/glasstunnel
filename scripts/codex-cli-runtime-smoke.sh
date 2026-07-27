#!/usr/bin/env bash
# Privacy-safe Codex CLI runtime audit for release verification.
#
# This verifies the installed Codex CLI flag surface and the Swift launch/runtime
# contract Glasstunnel uses. It does not start an agent session, read Codex
# config values, or print prompts, responses, workspace roots, or credentials.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "Glasstunnel Codex CLI runtime audit"
echo "Date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "Commit: $(git rev-parse --short HEAD 2>/dev/null || printf unknown)"
echo

echo "==> Installed Codex CLI flag surface"
pnpm qa:codex-cli
echo

echo "==> Glasstunnel Codex CLI launch/runtime contract"
swift test --package-path apps/host-macos --filter CodexRuntimeCatalogTests
swift test --package-path apps/host-macos --filter "AdapterFactoryTests/testCodex"
swift test --package-path apps/host-macos --filter "RemoteAppControllerTests/testCodexCli"
echo

echo "Result: passed; Codex CLI runtime audit covered installed CLI flags, launch arguments, runtime update restart arguments, runtime value cleanup, malformed runtime value rejection, rollback snapshots, executable candidates, and local publication candidate reuse."
echo "This does not start a live Codex agent session. Signed-in mobile start, prompt, interrupt, done-state, and runtime-change verification remain required."
