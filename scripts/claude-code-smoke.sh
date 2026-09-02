#!/usr/bin/env bash
# Privacy-safe Claude Code CLI smoke for release verification.
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

run_runtime_probe() {
  local output_file="$1"
  local marker="GT_CLAUDE_OK"

  set +e
  perl -e 'alarm 90; exec @ARGV' claude --bare --print "Reply with exactly: $marker" >"$output_file" 2>&1
  local probe_status=$?
  set -e

  if grep -Fq "$marker" "$output_file"; then
    printf '| Runtime prompt | pass | Claude Code returned the expected marker. |\n'
    return 0
  fi

  if grep -Eiq 'login|auth|credential|api key|ANTHROPIC_API_KEY|subscription|not authenticated|requires.*auth|setup-token' "$output_file"; then
    printf '| Runtime prompt | blocked | Claude Code requires local auth before prompts can run. |\n'
    return 2
  fi

  if [[ "$probe_status" -ne 0 ]]; then
    printf '| Runtime prompt | fail | Claude Code exited with status %s. |\n' "$probe_status"
    return 1
  fi

  printf '| Runtime prompt | fail | Claude Code did not return the expected marker. |\n'
  return 1
}

printf 'Glasstunnel Claude Code CLI smoke\n'
printf 'Date: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf 'Commit: %s\n\n' "$(git rev-parse --short HEAD 2>/dev/null || printf unknown)"

claude_path="$(command -v claude 2>/dev/null || true)"
if [[ -z "$claude_path" ]]; then
  printf 'Claude Code CLI: missing\n'
  printf 'Result: blocked; install Claude Code CLI before Claude Code release verification.\n'
  exit 1
fi

version="$(claude --version 2>&1 | sed -n '1p' || true)"
help_text="$(claude --help 2>&1 || true)"
auth_help_text="$(claude auth --help 2>&1 || true)"

printf 'Claude Code CLI: present: %s\n' "$(redact_home "$claude_path")"
printf 'Claude Code CLI version: %s\n\n' "${version:-unknown}"
printf '| Check | Status | Detail |\n'
printf '| --- | --- | --- |\n'
check_contains 'Interactive launch form' "$help_text" 'claude [options] [command] [prompt]'
check_contains 'Print mode' "$help_text" '--print'
check_contains 'Model flag' "$help_text" '--model'
check_contains 'Effort flag' "$help_text" '--effort'
check_contains 'Resume flag' "$help_text" '--resume'
check_contains 'Session id flag' "$help_text" '--session-id'
check_contains 'Continue flag' "$help_text" '--continue'
check_contains 'Permission mode flag' "$help_text" '--permission-mode'
check_contains 'Settings flag' "$help_text" '--settings'
check_contains 'Auth command' "$help_text" 'auth'
check_contains 'Auth help' "$auth_help_text" 'Manage authentication'

runtime_status=0
runtime_probe_file="$(mktemp -t glasstunnel-claude-code-runtime)"
cleanup() {
  rm -f "$runtime_probe_file"
}
trap cleanup EXIT

if [[ "${GT_CLAUDE_CODE_RUNTIME_PROBE:-0}" == "1" ]]; then
  run_runtime_probe "$runtime_probe_file" || runtime_status=$?
fi

printf '\n'
if [[ "$failures" -gt 0 ]]; then
  printf 'Result: failed; Claude Code flag surface does not match Glasstunnel launch assumptions.\n' >&2
  exit 1
fi

case "$runtime_status" in
  0)
    if [[ "${GT_CLAUDE_CODE_RUNTIME_PROBE:-0}" == "1" ]]; then
      printf 'Result: passed; Claude Code flag surface and runtime prompt probe passed.\n'
    else
      printf 'Result: passed; Claude Code flag surface matches Glasstunnel launch assumptions. Runtime prompt probe was not requested.\n'
    fi
    ;;
  2)
    printf 'Result: partial; Claude Code is installed and its flag surface matches, but runtime prompt verification is blocked on local auth configuration.\n'
    if [[ "${GT_CLAUDE_CODE_REQUIRE_RUNTIME:-0}" == "1" ]]; then
      exit 1
    fi
    ;;
  *)
    printf 'Result: failed; Claude Code runtime prompt probe did not pass.\n' >&2
    exit 1
    ;;
esac
