#!/usr/bin/env bash
# Privacy-safe Gemini CLI smoke for release verification.
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
  local marker="GT_GEMINI_OK"

  set +e
  perl -e 'alarm 60; exec @ARGV' gemini --skip-trust -p "Reply with exactly: $marker" >"$output_file" 2>&1
  local status=$?
  set -e

  if grep -Fq "$marker" "$output_file"; then
    printf '| Runtime prompt | pass | Gemini CLI returned the expected marker. |\n'
    return 0
  fi

  if grep -Fq 'Please set an Auth method' "$output_file"; then
    printf '| Runtime prompt | blocked | Gemini CLI requires local auth configuration before prompts can run. |\n'
    return 2
  fi

  if [[ "$status" -ne 0 ]]; then
    printf '| Runtime prompt | fail | Gemini CLI exited with status %s. |\n' "$status"
    return 1
  fi

  printf '| Runtime prompt | fail | Gemini CLI did not return the expected marker. |\n'
  return 1
}

printf 'Glasstunnel Gemini CLI smoke\n'
printf 'Date: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf 'Commit: %s\n\n' "$(git rev-parse --short HEAD 2>/dev/null || printf unknown)"

gemini_path="$(command -v gemini 2>/dev/null || true)"
if [[ -z "$gemini_path" ]]; then
  printf 'Gemini CLI: missing\n'
  printf 'Result: blocked; install Gemini CLI before Gemini CLI release verification.\n'
  exit 1
fi

version="$(gemini --version 2>/dev/null | sed -n '1p' || true)"
help_text="$(gemini --help 2>/dev/null || true)"

printf 'Gemini CLI: present: %s\n' "$(redact_home "$gemini_path")"
printf 'Gemini CLI version: %s\n\n' "${version:-unknown}"
printf '| Check | Status | Detail |\n'
printf '| --- | --- | --- |\n'
check_contains 'Prompt flag' "$help_text" '--prompt'
check_contains 'Model flag' "$help_text" '--model'
check_contains 'Resume flag' "$help_text" '--resume'
check_contains 'List sessions flag' "$help_text" '--list-sessions'
check_contains 'Interactive launch form' "$help_text" 'gemini [query..]'

runtime_status=0
runtime_probe_file="$(mktemp -t glasstunnel-gemini-cli-runtime)"
cleanup() {
  rm -f "$runtime_probe_file"
}
trap cleanup EXIT

if [[ "${GT_GEMINI_CLI_RUNTIME_PROBE:-0}" == "1" ]]; then
  run_runtime_probe "$runtime_probe_file" || runtime_status=$?
fi

printf '\n'
if [[ "$failures" -gt 0 ]]; then
  printf 'Result: failed; Gemini CLI flag surface does not match Glasstunnel launch assumptions.\n' >&2
  exit 1
fi

case "$runtime_status" in
  0)
    if [[ "${GT_GEMINI_CLI_RUNTIME_PROBE:-0}" == "1" ]]; then
      printf 'Result: passed; Gemini CLI flag surface and runtime prompt probe passed.\n'
    else
      printf 'Result: passed; Gemini CLI flag surface matches Glasstunnel launch assumptions. Runtime prompt probe was not requested.\n'
    fi
    ;;
  2)
    printf 'Result: partial; Gemini CLI is installed and its flag surface matches, but runtime prompt verification is blocked on local auth configuration.\n'
    if [[ "${GT_GEMINI_CLI_REQUIRE_RUNTIME:-0}" == "1" ]]; then
      exit 1
    fi
    ;;
  *)
    printf 'Result: failed; Gemini CLI runtime prompt probe did not pass.\n' >&2
    exit 1
    ;;
esac
