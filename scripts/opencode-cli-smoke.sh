#!/usr/bin/env bash
# Privacy-safe OpenCode CLI smoke for release verification.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

redact_sensitive_file() {
  local input_file="$1"
  local output_file="$2"
  perl -pe '
    s/\e\[[0-9;?]*[ -\/]*[@-~]//g;
    s/\Q$ENV{HOME}\E/~/g if defined $ENV{HOME};
    s/(sk-[A-Za-z0-9_-]{8,})/sk-<redacted>/g;
    s/(gh[pousr]_[A-Za-z0-9_]{8,})/gh-<redacted>/g;
    s/(xox[baprs]-[A-Za-z0-9-]{8,})/xox-<redacted>/g;
    s/((?:api[_ -]?key|token|secret|authorization|credential)[^\n:=]*[:=]\s*)\S+/${1}<redacted>/ig;
    s/[A-Za-z0-9+\/_=.-]{48,}/<redacted>/g;
  ' "$input_file" >"$output_file"
}

sanitize_model_filename() {
  local value="$1"
  printf '%s' "$value" | tr -c 'A-Za-z0-9._-' '_'
}

runtime_status_label() {
  case "$1" in
    0) printf 'pass' ;;
    2) printf 'blocked' ;;
    *) printf 'fail' ;;
  esac
}

run_provider_auth_probe() {
  local output_file="$1"
  local raw_output_file credential_count credential_names
  raw_output_file="$(mktemp -t glasstunnel-opencode-provider-auth-raw)"

  set +e
  perl -e 'alarm 30; exec @ARGV' opencode providers list --pure >"$raw_output_file" 2>&1
  local probe_status=$?
  set -e

  redact_sensitive_file "$raw_output_file" "$output_file"
  rm -f "$raw_output_file"

  if [[ "$probe_status" -ne 0 ]]; then
    printf '| Provider credentials | fail | `opencode providers list --pure` exited with status %s. |\n' "$probe_status"
    return 1
  fi

  credential_count="$(grep -Eo '[0-9]+ credentials?' "$output_file" | tail -1 | awk '{print $1}')"
  credential_count="${credential_count:-0}"
  if [[ "$credential_count" -le 0 ]]; then
    printf '| Provider credentials | blocked | OpenCode provider list reports no configured credentials; free `opencode/` models may still run. |\n'
    return 2
  fi

  credential_names="$(
    awk '
      /^[[:space:]]*●[[:space:]]/ {
        sub(/^[[:space:]]*●[[:space:]]*/, "", $0)
        sub(/[[:space:]]+api[[:space:]]*$/, "", $0)
        print
      }
    ' "$output_file" | paste -sd ', ' -
  )"
  if [[ -n "$credential_names" ]]; then
    printf '| Provider credentials | pass | OpenCode provider list reports %s configured credential(s): %s. |\n' "$credential_count" "$credential_names"
  else
    printf '| Provider credentials | pass | OpenCode provider list reports %s configured credential(s). |\n' "$credential_count"
  fi
  return 0
}

run_runtime_probe() {
  local output_file="$1"
  local runtime_model="${2-${GT_OPENCODE_CLI_RUNTIME_MODEL:-opencode/nemotron-3-ultra-free}}"
  local check_name="${3:-Runtime prompt}"
  local marker="GT_OPENCODE_OK"
  local command=(opencode run "Reply with exactly: $marker")

  if [[ -n "$runtime_model" ]]; then
    command=(opencode run --model "$runtime_model" "Reply with exactly: $marker")
  fi

  set +e
  perl -e 'alarm 60; exec @ARGV' "${command[@]}" >"$output_file" 2>&1
  local probe_status=$?
  set -e

  if grep -Fq "$marker" "$output_file"; then
    if [[ -n "$runtime_model" ]]; then
      printf '| %s | pass | OpenCode CLI returned the expected marker with `%s`. |\n' "$check_name" "$runtime_model"
    else
      printf '| %s | pass | OpenCode CLI returned the expected marker with its default model. |\n' "$check_name"
    fi
    return 0
  fi

  if grep -Eiq 'login|auth|credential|provider|api key|not configured' "$output_file"; then
    printf '| %s | blocked | OpenCode CLI requires provider credentials before prompts can run. |\n' "$check_name"
    return 2
  fi

  if grep -Eiq 'model is disabled|disabled model|model.*disabled' "$output_file"; then
    if [[ -n "$runtime_model" ]]; then
      printf '| %s | blocked | OpenCode provider/model `%s` is disabled for this account. |\n' "$check_name" "$runtime_model"
    else
      printf '| %s | blocked | OpenCode default provider/model is disabled for this account. |\n' "$check_name"
    fi
    return 2
  fi

  if grep -Eiq 'insufficient balance|billing|payment required|no credits?|quota|rate limit|rate-limited|too many requests|not authorized|unauthorized|forbidden|not enabled' "$output_file"; then
    if [[ -n "$runtime_model" ]]; then
      printf '| %s | blocked | OpenCode provider/model `%s` is blocked by account, billing, quota, or authorization state. |\n' "$check_name" "$runtime_model"
    else
      printf '| %s | blocked | OpenCode default provider/model is blocked by account, billing, quota, or authorization state. |\n' "$check_name"
    fi
    return 2
  fi

  if [[ "$probe_status" -ne 0 ]]; then
    printf '| %s | fail | OpenCode CLI exited with status %s. |\n' "$check_name" "$probe_status"
    return 1
  fi

  printf '| %s | fail | OpenCode CLI did not return the expected marker. |\n' "$check_name"
  return 1
}

run_model_matrix_probe() {
  local matrix="$1"
  local output_dir="$2"
  local matrix_status=0
  local blocked_without_expectation=0
  local entry model expected output_file probe_status actual

  IFS=',' read -r -a entries <<<"$matrix"
  for entry in "${entries[@]}"; do
    entry="$(trim_value "$entry")"
    [[ -z "$entry" ]] && continue

    expected=""
    model="$entry"
    if [[ "$entry" == *"="* ]]; then
      model="$(trim_value "${entry%%=*}")"
      expected="$(trim_value "${entry#*=}")"
    fi

    if [[ -z "$model" ]]; then
      printf '| Model runtime expectation | fail | Empty OpenCode model entry in matrix. |\n'
      matrix_status=1
      continue
    fi

    case "$expected" in
      ""|pass|blocked|fail) ;;
      *)
        printf '| Model runtime expectation | fail | Invalid expected status `%s` for `%s`; use pass, blocked, or fail. |\n' "$expected" "$model"
        matrix_status=1
        continue
        ;;
    esac

    output_file="$output_dir/$(sanitize_model_filename "$model").txt"
    probe_status=0
    run_runtime_probe "$output_file" "$model" "Model runtime $model" || probe_status=$?
    actual="$(runtime_status_label "$probe_status")"

    if [[ -n "$expected" ]]; then
      if [[ "$actual" == "$expected" ]]; then
        printf '| Model runtime expectation | pass | `%s` matched expected `%s`. |\n' "$model" "$expected"
      else
        printf '| Model runtime expectation | fail | `%s` was `%s`; expected `%s`. |\n' "$model" "$actual" "$expected"
        matrix_status=1
      fi
    elif [[ "$probe_status" -eq 2 ]]; then
      blocked_without_expectation=1
    elif [[ "$probe_status" -ne 0 ]]; then
      matrix_status=1
    fi
  done

  if [[ "$matrix_status" -ne 0 ]]; then
    return 1
  fi
  if [[ "$blocked_without_expectation" -ne 0 ]]; then
    return 2
  fi
  return 0
}

run_model_catalog_probe() {
  local output_file="$1"
  local required_model="${GT_OPENCODE_CLI_CATALOG_MODEL:-opencode/deepseek-v4-flash-free}"

  set +e
  perl -e 'alarm 45; exec @ARGV' opencode models opencode --pure >"$output_file" 2>&1
  local probe_status=$?
  set -e

  if [[ "$probe_status" -ne 0 ]]; then
    printf '| Model catalog | fail | `opencode models opencode --pure` exited with status %s. |\n' "$probe_status"
    return 1
  fi

  local model_count
  model_count="$(grep -Ec '^opencode/' "$output_file" || true)"
  if [[ "$model_count" -le 0 ]]; then
    printf '| Model catalog | fail | No `opencode/` models were listed. |\n'
    return 1
  fi

  if ! grep -Fxq "$required_model" "$output_file"; then
    printf '| Model catalog | fail | Required model `%s` was not listed among %s OpenCode models. |\n' "$required_model" "$model_count"
    return 1
  fi

  printf '| Model catalog | pass | Listed %s OpenCode models including `%s`. |\n' "$model_count" "$required_model"
  return 0
}

run_static_catalog_match_probe() {
  local output_file="$1"
  local adapter_file="$ROOT_DIR/apps/host-macos/Sources/Adapters/OpenCode/OpenCodeAdapter.swift"
  local live_models static_models missing_models extra_models live_count static_count

  if [[ ! -s "$output_file" ]]; then
    run_model_catalog_probe "$output_file" || return $?
  fi

  if [[ ! -f "$adapter_file" ]]; then
    printf '| Mac static model catalog | fail | OpenCode adapter file was not found. |\n'
    return 1
  fi

  live_models="$(mktemp -t glasstunnel-opencode-live-models)"
  static_models="$(mktemp -t glasstunnel-opencode-static-models)"
  grep -E '^opencode/' "$output_file" | sort -u >"$live_models" || true
  perl -ne 'print "$1\n" if /"(opencode\/[^"]+)"/' "$adapter_file" | sort -u >"$static_models"

  live_count="$(wc -l <"$live_models" | tr -d ' ')"
  static_count="$(wc -l <"$static_models" | tr -d ' ')"
  missing_models="$(comm -23 "$live_models" "$static_models" | paste -sd ',' - | sed 's/,/, /g')"
  extra_models="$(comm -13 "$live_models" "$static_models" | paste -sd ',' - | sed 's/,/, /g')"

  rm -f "$live_models" "$static_models"

  if [[ -n "$missing_models" || -n "$extra_models" ]]; then
    if [[ -n "$missing_models" ]]; then
      printf '| Mac static model catalog | fail | Live OpenCode catalog models missing from Mac options: %s. |\n' "$missing_models"
    fi
    if [[ -n "$extra_models" ]]; then
      printf '| Mac static model catalog | fail | Mac options include models not listed by the current OpenCode CLI: %s. |\n' "$extra_models"
    fi
    return 1
  fi

  printf '| Mac static model catalog | pass | Swift OpenCode model options match the live CLI catalog (%s models). |\n' "$live_count"
  if [[ "$live_count" != "$static_count" ]]; then
    printf '| Mac static model catalog count | fail | Live catalog count %s differed from static count %s. |\n' "$live_count" "$static_count"
    return 1
  fi
  return 0
}

export_artifacts() {
  local artifact_dir="${GT_OPENCODE_CLI_ARTIFACT_DIR:-}"
  [[ -z "$artifact_dir" ]] && return 0

  mkdir -p "$artifact_dir"
  if [[ -s "$provider_auth_file" ]]; then
    cp "$provider_auth_file" "$artifact_dir/provider-credentials.txt"
  fi
  if [[ -s "$runtime_probe_file" ]]; then
    redact_sensitive_file "$runtime_probe_file" "$artifact_dir/runtime-prompt.txt"
  fi
  if [[ -s "$model_catalog_file" ]]; then
    redact_sensitive_file "$model_catalog_file" "$artifact_dir/model-catalog.txt"
  fi

  local model_file model_name
  shopt -s nullglob
  for model_file in "$model_matrix_dir"/*.txt; do
    model_name="$(basename "$model_file")"
    redact_sensitive_file "$model_file" "$artifact_dir/model-$model_name"
  done
  shopt -u nullglob
}

printf 'Glasstunnel OpenCode CLI smoke\n'
printf 'Date: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf 'Commit: %s\n\n' "$(git rev-parse --short HEAD 2>/dev/null || printf unknown)"

opencode_path="$(command -v opencode 2>/dev/null || true)"
if [[ -z "$opencode_path" ]]; then
  printf 'OpenCode CLI: missing\n'
  printf 'Result: blocked; install OpenCode CLI before OpenCode release verification.\n'
  exit 1
fi

version="$(opencode --version 2>&1 | sed -n '1p' || true)"
help_text="$(opencode --help 2>&1 || true)"
run_help_text="$(opencode run --help 2>&1 || true)"
session_help_text="$(opencode session --help 2>&1 || true)"
providers_help_text="$(opencode providers --help 2>&1 || true)"

printf 'OpenCode CLI: present: %s\n' "$(redact_home "$opencode_path")"
printf 'OpenCode CLI version: %s\n\n' "${version:-unknown}"
printf '| Check | Status | Detail |\n'
printf '| --- | --- | --- |\n'
check_contains 'Interactive launch form' "$help_text" 'opencode [project]'
check_contains 'Run command' "$help_text" 'opencode run [message..]'
check_contains 'Session command' "$help_text" 'opencode session'
check_contains 'Provider auth command' "$help_text" 'opencode providers'
check_contains 'Run model flag' "$run_help_text" '--model'
check_contains 'Run session flag' "$run_help_text" '--session'
check_contains 'Run continue flag' "$run_help_text" '--continue'
check_contains 'Run variant flag' "$run_help_text" '--variant'
check_contains 'Session list command' "$session_help_text" 'opencode session list'
check_contains 'Provider login command' "$providers_help_text" 'opencode providers login'

passed_summary="flag surface"
partial_status=0
provider_status=0
runtime_status=0
catalog_status=0
static_catalog_status=0
matrix_status=0
provider_auth_file="$(mktemp -t glasstunnel-opencode-provider-auth)"
runtime_probe_file="$(mktemp -t glasstunnel-opencode-cli-runtime)"
model_catalog_file="$(mktemp -t glasstunnel-opencode-cli-models)"
model_matrix_dir="$(mktemp -d -t glasstunnel-opencode-cli-model-matrix)"
cleanup() {
  rm -f "$provider_auth_file" "$runtime_probe_file" "$model_catalog_file"
  rm -rf "$model_matrix_dir"
}
trap cleanup EXIT

if [[ "${GT_OPENCODE_CLI_PROVIDER_AUTH_PROBE:-0}" == "1" ]]; then
  passed_summary="$passed_summary, provider credentials"
  run_provider_auth_probe "$provider_auth_file" || provider_status=$?
fi
if [[ "${GT_OPENCODE_CLI_RUNTIME_PROBE:-0}" == "1" ]]; then
  passed_summary="$passed_summary, runtime prompt probe"
  run_runtime_probe "$runtime_probe_file" || runtime_status=$?
fi
if [[ "${GT_OPENCODE_CLI_MODEL_CATALOG_PROBE:-0}" == "1" ]]; then
  passed_summary="$passed_summary, model catalog"
  run_model_catalog_probe "$model_catalog_file" || catalog_status=$?
fi
if [[ "${GT_OPENCODE_CLI_CATALOG_MATCH_SWIFT:-0}" == "1" ]]; then
  passed_summary="$passed_summary, Mac model catalog parity"
  run_static_catalog_match_probe "$model_catalog_file" || static_catalog_status=$?
fi
if [[ -n "${GT_OPENCODE_CLI_MODEL_MATRIX:-}" ]]; then
  passed_summary="$passed_summary, model matrix"
  run_model_matrix_probe "$GT_OPENCODE_CLI_MODEL_MATRIX" "$model_matrix_dir" || matrix_status=$?
fi

export_artifacts

printf '\n'
if [[ "$failures" -gt 0 ]]; then
  printf 'Result: failed; OpenCode CLI flag surface does not match Glasstunnel launch assumptions.\n' >&2
  exit 1
fi
case "$provider_status" in
  0) ;;
  2)
    printf 'Result: partial; OpenCode provider credentials are missing or unavailable for private-provider verification.\n'
    partial_status=1
    if [[ "${GT_OPENCODE_CLI_REQUIRE_PROVIDER_AUTH:-0}" == "1" ]]; then
      exit 1
    fi
    ;;
  *)
    printf 'Result: failed; OpenCode provider credential probe did not pass.\n' >&2
    exit 1
    ;;
esac
if [[ "$catalog_status" -ne 0 ]]; then
  printf 'Result: failed; OpenCode CLI model catalog probe did not pass.\n' >&2
  exit 1
fi
if [[ "$static_catalog_status" -ne 0 ]]; then
  printf 'Result: failed; OpenCode CLI catalog and Mac model options are out of sync.\n' >&2
  exit 1
fi
case "$matrix_status" in
  0) ;;
  2)
    printf 'Result: partial; OpenCode CLI model matrix contains provider/model entries blocked by credentials or availability.\n'
    partial_status=1
    if [[ "${GT_OPENCODE_CLI_REQUIRE_MODEL_MATRIX:-0}" == "1" ]]; then
      exit 1
    fi
    ;;
  *)
    printf 'Result: failed; OpenCode CLI model matrix probe did not match expectations.\n' >&2
    exit 1
    ;;
esac

case "$runtime_status" in
  0)
    if [[ "$partial_status" -ne 0 ]]; then
      printf 'Result: partial; OpenCode CLI flag surface passed, but one or more optional probes are blocked.\n'
    else
      printf 'Result: passed; OpenCode CLI %s passed.\n' "$passed_summary"
    fi
    ;;
  2)
    printf 'Result: partial; OpenCode CLI is installed and its flag surface matches, but runtime prompt verification is blocked on provider credentials or selected model availability.\n'
    if [[ "${GT_OPENCODE_CLI_REQUIRE_RUNTIME:-0}" == "1" ]]; then
      exit 1
    fi
    ;;
  *)
    printf 'Result: failed; OpenCode CLI runtime prompt probe did not pass.\n' >&2
    exit 1
    ;;
esac
