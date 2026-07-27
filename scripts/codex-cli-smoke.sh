#!/usr/bin/env bash
# Privacy-safe Codex CLI smoke for release verification.
set -euo pipefail

redact_home() {
  local value="$1"
  printf '%s' "${value/#$HOME/~}"
}

failures=0

check_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    printf '| %s | pass | Found `%s` |\n' "$name" "$needle"
  else
    printf '| %s | fail | Missing `%s` |\n' "$name" "$needle"
    failures=$((failures + 1))
  fi
}

printf 'Glasstunnel Codex CLI smoke\n'
printf 'Date: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf 'Commit: %s\n\n' "$(git rev-parse --short HEAD 2>/dev/null || printf unknown)"

codex_path="$(command -v codex 2>/dev/null || true)"
if [[ -z "$codex_path" ]]; then
  printf 'Codex CLI: missing\n'
  printf 'Result: blocked; install Codex CLI before Codex CLI release verification.\n'
  exit 1
fi

version="$(codex --version 2>/dev/null | sed -n '1p' || true)"
help_text="$(codex --help 2>/dev/null || true)"

printf 'Codex CLI: present: %s\n' "$(redact_home "$codex_path")"
printf 'Codex CLI version: %s\n\n' "${version:-unknown}"
printf '| Check | Status | Detail |\n'
printf '| --- | --- | --- |\n'
check_contains 'No alternate screen' "$help_text" '--no-alt-screen'
check_contains 'Model flag' "$help_text" '--model'
check_contains 'Config override' "$help_text" '--config <key=value>'
check_contains 'Interactive prompt form' "$help_text" 'codex [OPTIONS] [PROMPT]'
check_contains 'Exec command' "$help_text" 'exec'

printf '\n'
if [[ "$failures" -gt 0 ]]; then
  printf 'Result: failed; Codex CLI flag surface does not match Glasstunnel launch assumptions.\n' >&2
  exit 1
fi

printf 'Result: passed; Codex CLI flag surface matches Glasstunnel launch assumptions.\n'
