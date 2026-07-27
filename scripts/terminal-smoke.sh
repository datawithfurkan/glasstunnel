#!/usr/bin/env bash
# Privacy-safe Terminal adapter smoke for release verification.
set -euo pipefail

redact_home() {
  local value="$1"
  printf '%s' "${value/#$HOME/~}"
}

shell_path="${SHELL:-/bin/zsh}"

printf 'Glasstunnel Terminal smoke\n'
printf 'Date: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf 'Commit: %s\n' "$(git rev-parse --short HEAD 2>/dev/null || printf unknown)"
printf 'Shell: %s\n\n' "$(redact_home "$shell_path")"

if [[ ! -x "$shell_path" ]]; then
  printf 'Result: failed; configured shell is not executable.\n' >&2
  exit 1
fi

swift test --package-path apps/host-macos --filter TerminalAdapterTests

printf '\nResult: passed; Terminal adapter starts a real PTY, runs commands, interrupts a long command, and accepts the next command.\n'
