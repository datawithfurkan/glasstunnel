#!/usr/bin/env bash
# Aggregate the live/manual evidence gates required before public release.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRED_COMMIT="${GT_MANUAL_RELEASE_REQUIRED_COMMIT:-$(git -C "$ROOT_DIR" rev-parse --short HEAD)}"
MAC_EVIDENCE_DIR="${GT_MAC_LIVE_EVIDENCE_DIR:-$ROOT_DIR/docs/release-evidence/mac-app}"
MOBILE_EVIDENCE_DIR="${GT_REAL_MOBILE_EVIDENCE_DIR:-$ROOT_DIR/docs/release-evidence/mobile}"
AGENT_APP_EVIDENCE_DIR="${GT_AGENT_APP_EVIDENCE_DIR:-$ROOT_DIR/docs/release-evidence/agent-apps}"
REQUIRED_AGENT_APPS="${GT_MANUAL_REQUIRED_AGENT_APPS:-Mac Screen|Terminal}"
REQUIRE_PHYSICAL="${GT_MANUAL_RELEASE_REQUIRE_PHYSICAL:-0}"
FAILURES=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/check-manual-release-gates.sh

Checks the current-commit manual release evidence that cannot be replaced by
simulators, fixtures, local-only unit tests, or broad automated readiness runs.

Default gates:
  - live bundled Mac app evidence for permission-onboarding and auth-relaunch
  - required real app-support passes, default: Mac Screen and Terminal

Optional gate:
  - physical-phone Safari and Chrome evidence when
    GT_MANUAL_RELEASE_REQUIRE_PHYSICAL=1

Environment:
  GT_MANUAL_RELEASE_REQUIRED_COMMIT  Commit prefix records must match. Defaults to current HEAD.
  GT_MANUAL_REQUIRED_AGENT_APPS      Pipe-separated app names. Default: "Mac Screen|Terminal".
  GT_MANUAL_RELEASE_REQUIRE_PHYSICAL Set to 1 only for an explicit hardware gate.
  GT_MAC_LIVE_EVIDENCE_DIR          Override Mac live evidence directory.
  GT_REAL_MOBILE_EVIDENCE_DIR       Override real-phone mobile evidence directory.
  GT_AGENT_APP_EVIDENCE_DIR         Override agent-app evidence directory.
  GT_MAC_LIVE_REQUIRED_SCOPES       Override live Mac scopes.
  GT_REAL_MOBILE_REQUIRED_BROWSERS  Override physical-phone browsers.
  GT_REAL_MOBILE_REQUIRED_SCOPES    Override physical-phone scopes.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

case "$REQUIRE_PHYSICAL" in
  0|1) ;;
  *)
    echo "GT_MANUAL_RELEASE_REQUIRE_PHYSICAL must be 0 or 1." >&2
    exit 2
    ;;
esac

field_value_for_record() {
  local file="$1"
  local field="$2"
  local line

  line="$(grep -m1 -E "^- $field: " "$file" || true)"
  printf '%s' "${line#- $field: }"
}

artifact_path_for_record() {
  local file="$1"
  local artifact

  artifact="$(field_value_for_record "$file" "Artifact")"
  if [[ -z "$artifact" ]]; then
    artifact="$(field_value_for_record "$file" "Screenshot or recording")"
  fi
  printf '%s' "$artifact"
}

artifact_exists_for_record() {
  local file="$1"
  local artifact
  local evidence_relative

  artifact="$(artifact_path_for_record "$file")"
  [[ -n "$artifact" ]] || return 1

  if [[ "$artifact" = /* ]]; then
    [[ -e "$artifact" ]]
    return
  fi

  evidence_relative="$(dirname "$file")/$artifact"
  [[ -e "$evidence_relative" || -e "$ROOT_DIR/$artifact" ]]
}

section_text_for_record() {
  local file="$1"
  local section="$2"

  awk -v target="## $section" '
    $0 == target { in_section = 1; next }
    in_section && /^## / { exit }
    in_section { print }
  ' "$file"
}

normalized_lowercase() {
  printf '%s' "$1" | tr '\n' ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' | tr '[:upper:]' '[:lower:]'
}

has_meaningful_passed_section() {
  local file="$1"
  local passed

  passed="$(normalized_lowercase "$(section_text_for_record "$file" "Passed")")"
  case "$passed" in
    ""|"not recorded."|"none."|"n/a"|"na")
      return 1
      ;;
  esac
}

has_privacy_review() {
  grep -Fqx -- "- Privacy review: pass" "$1"
}

has_app_specific_passed_section() {
  local file="$1"
  local app="$2"
  local passed

  passed="$(normalized_lowercase "$(section_text_for_record "$file" "Passed")")"

  case "$app" in
    "Codex desktop")
      case "$passed" in
        *label*|*name*) ;;
        *) return 1 ;;
      esac
      case "$passed" in
        *prompt*) ;;
        *) return 1 ;;
      esac
      case "$passed" in
        *status*|*result*|*response*) ;;
        *) return 1 ;;
      esac
      ;;
    "Codex CLI")
      case "$passed" in
        *start*|*started*|*launch*|*session*) ;;
        *) return 1 ;;
      esac
      case "$passed" in
        *prompt*) ;;
        *) return 1 ;;
      esac
      case "$passed" in
        *interrupt*|*stop*|*cancel*) ;;
        *) return 1 ;;
      esac
      case "$passed" in
        *done*|*status*|*result*|*response*) ;;
        *) return 1 ;;
      esac
      case "$passed" in
        *model*|*runtime*|*effort*|*fast*) ;;
        *) return 1 ;;
      esac
      ;;
    "Cursor")
      case "$passed" in
        *project*|*chat*|*context*|*target*) ;;
        *) return 1 ;;
      esac
      case "$passed" in
        *prompt*|*input*) ;;
        *) return 1 ;;
      esac
      case "$passed" in
        *submit*|*return*|*send*) ;;
        *) return 1 ;;
      esac
      case "$passed" in
        *foreground*|*background*) ;;
        *) return 1 ;;
      esac
      case "$passed" in
        *model*|*setting*|*settings*|*composer*) ;;
        *) return 1 ;;
      esac
      ;;
    "Terminal")
      case "$passed" in
        *command*) ;;
        *) return 1 ;;
      esac
      case "$passed" in
        *output*|*stream*) ;;
        *) return 1 ;;
      esac
      case "$passed" in
        *long-running*|*long\ running*|*sleep*|*process*) ;;
        *) return 1 ;;
      esac
      case "$passed" in
        *interrupt*|*stop*|*cancel*) ;;
        *) return 1 ;;
      esac
      case "$passed" in
        *recover*|*recovery*|*next\ command*|*accepts\ next*|*status*) ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

is_evidence_neutral_path() {
  case "$1" in
    docs/*|scripts/check-*|scripts/record-*|scripts/*-smoke.sh|package.json|README.md|CONTRIBUTING.md|SECURITY.md|CODE_OF_CONDUCT.md|CHANGELOG.md|.github/*|.gitleaks.toml|.gitignore|.nvmrc)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

record_matches_required_commit() {
  local file="$1"
  local commit
  local evidence_commit
  local required_commit
  local changed_path

  commit="$(field_value_for_record "$file" "Glasstunnel commit")"
  [[ -n "$commit" && -n "$REQUIRED_COMMIT" ]] || return 1
  if [[ "$commit" == "$REQUIRED_COMMIT"* || "$REQUIRED_COMMIT" == "$commit"* ]]; then
    return 0
  fi

  evidence_commit="$(git -C "$ROOT_DIR" rev-parse --verify "${commit}^{commit}" 2>/dev/null)" || return 1
  required_commit="$(git -C "$ROOT_DIR" rev-parse --verify "${REQUIRED_COMMIT}^{commit}" 2>/dev/null)" || return 1
  git -C "$ROOT_DIR" merge-base --is-ancestor "$evidence_commit" "$required_commit" || return 1

  while IFS= read -r changed_path; do
    [[ -n "$changed_path" ]] || continue
    is_evidence_neutral_path "$changed_path" || return 1
  done < <(git -C "$ROOT_DIR" diff --name-only "$evidence_commit..$required_commit" --)
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-//; s/-$//'
}

has_agent_app_pass_record() {
  local app="$1"
  local key
  local file

  key="$(slugify "$app")"
  shopt -s nullglob
  for file in "$AGENT_APP_EVIDENCE_DIR"/"$key"-*.md; do
    if grep -Fqx -- "- App: $app" "$file" \
      && grep -Fqx -- "- Result: pass" "$file" \
      && record_matches_required_commit "$file" \
      && artifact_exists_for_record "$file" \
      && has_privacy_review "$file" \
      && has_meaningful_passed_section "$file" \
      && has_app_specific_passed_section "$file" "$app"; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

run_gate() {
  local label="$1"
  shift

  echo
  echo "==> $label"
  if "$@"; then
    printf '%-36s pass\n' "$label"
  else
    printf '%-36s missing\n' "$label"
    FAILURES=$((FAILURES + 1))
  fi
}

echo "Manual release gate check"
echo "Required commit: $REQUIRED_COMMIT"
echo "Mac evidence: $MAC_EVIDENCE_DIR"
echo "Mobile evidence: $MOBILE_EVIDENCE_DIR"
echo "Agent-app evidence: $AGENT_APP_EVIDENCE_DIR"
echo "Required agent apps: $REQUIRED_AGENT_APPS"
echo "Physical-phone evidence required: $REQUIRE_PHYSICAL"

run_gate "Live Mac app evidence" env \
  GT_MAC_LIVE_EVIDENCE_DIR="$MAC_EVIDENCE_DIR" \
  GT_MAC_LIVE_REQUIRED_COMMIT="$REQUIRED_COMMIT" \
  bash "$ROOT_DIR/scripts/check-mac-live-evidence.sh"

if [[ "$REQUIRE_PHYSICAL" == "1" ]]; then
  run_gate "Physical-phone mobile evidence" env \
    GT_REAL_MOBILE_EVIDENCE_DIR="$MOBILE_EVIDENCE_DIR" \
    GT_REAL_MOBILE_REQUIRED_COMMIT="$REQUIRED_COMMIT" \
    bash "$ROOT_DIR/scripts/check-real-mobile-evidence.sh"
else
  echo
  echo "==> Physical-phone mobile evidence"
  echo "Optional; no hardware-only release gate was requested."
fi

echo
echo "==> Required real app-support evidence"
if [[ ! -d "$AGENT_APP_EVIDENCE_DIR" ]]; then
  echo "Missing evidence directory: $AGENT_APP_EVIDENCE_DIR" >&2
  FAILURES=$((FAILURES + 1))
else
  IFS='|' read -r -a apps <<< "$REQUIRED_AGENT_APPS"
  for app in "${apps[@]}"; do
    app="$(printf '%s' "$app" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -n "$app" ]] || continue
    if has_agent_app_pass_record "$app"; then
      printf '%-36s pass\n' "$app"
    else
      printf '%-36s missing\n' "$app"
      FAILURES=$((FAILURES + 1))
    fi
  done
fi

echo
if [[ "$FAILURES" -gt 0 ]]; then
  echo "Manual release gates are incomplete." >&2
  echo "Record current-commit evidence with pnpm qa:mac:live and pnpm qa:agent-app:record after real manual testing." >&2
  if [[ "$REQUIRE_PHYSICAL" == "1" ]]; then
    echo "The requested hardware gate also needs pnpm qa:mobile:real evidence." >&2
  fi
  exit 1
fi

echo "Manual release gates are complete."
