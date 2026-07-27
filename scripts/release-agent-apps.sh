#!/usr/bin/env bash
# Run local automated agent-app release audits.
#
# This command aggregates privacy-safe checks that can run on a developer Mac
# without launching mobile sessions, printing prompts, or exposing workspace paths.
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

echo "Glasstunnel agent-app release audit"
echo "Repo: $ROOT_DIR"
echo "Commit: $(git rev-parse --short HEAD) $(git log -1 --pretty=%s)"
echo "Branch: $(git branch --show-current)"
echo

run_check "Local app availability" pnpm qa:local-apps
run_check "Local app availability smoke" pnpm qa:local-apps:smoke
run_check "OpenCode Desktop install/upgrade availability smoke" pnpm qa:opencode:desktop-install-upgrade
run_check "Codex desktop state audit smoke" pnpm qa:codex-state:smoke
run_check "Codex desktop state and label sources" pnpm qa:codex-state:labels
run_check "Codex CLI runtime contract" pnpm qa:codex-cli:runtime
run_check "Hosted CLI evidence artifacts" pnpm qa:hosted-cli:contracts
run_check "Cursor local state" pnpm qa:cursor-state
run_check "Claude Code CLI launch surface" pnpm qa:claude-code
run_check "Terminal PTY behavior" pnpm qa:terminal
run_check "Release-ready claim evidence" pnpm qa:agent-app-claims

echo "Agent-app local audit completed."
echo "This is automated local evidence only. Signed-in mobile prompt, interrupt, status, and label-parity passes are still required before claiming public release support."
