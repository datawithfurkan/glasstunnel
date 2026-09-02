#!/usr/bin/env bash
# Ensure app-support release-ready claims have matching real-app evidence.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${GT_AGENT_APP_REPO_DIR:-$ROOT_DIR}"
MATRIX_FILE="${GT_AGENT_APP_MATRIX:-$ROOT_DIR/docs/agent-app-support-matrix.md}"
EVIDENCE_DIR="${GT_AGENT_APP_EVIDENCE_DIR:-$ROOT_DIR/docs/release-evidence/agent-apps}"
REQUIRED_COMMIT="${GT_AGENT_APP_REQUIRED_COMMIT:-$(git -C "$REPO_DIR" rev-parse --short HEAD)}"
FAILURES=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/check-agent-app-release-claims.sh

Checks docs/agent-app-support-matrix.md for app rows marked release-ready.
Any release-ready app claim must have matching real-app evidence under
docs/release-evidence/agent-apps.

Environment:
  GT_AGENT_APP_MATRIX           Override support matrix path.
  GT_AGENT_APP_EVIDENCE_DIR     Override evidence directory.
  GT_AGENT_APP_REPO_DIR         Override the Git repository used for evidence ancestry.
  GT_AGENT_APP_REQUIRED_COMMIT  Commit evidence must match or precede through docs or
                                agent-neutral release-process changes.
                                Defaults to current HEAD.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

slugify() {
  lowercase "$1" | sed -E 's/[^a-z0-9]+/-/g; s/^-//; s/-$//'
}

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
  if [[ -z "$artifact" ]]; then
    return 1
  fi

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

# Paths that cannot change what ships: docs, release metadata, this check's own
# tooling, and the Mac host's unit tests (they never reach the binary).
is_agent_evidence_neutral_path() {
  case "$1" in
    Casks/glasstunnel.rb|\
CHANGELOG.md|\
README.md|\
docs/*|\
apps/host-macos/Tests/*|\
scripts/agent-app-release-claims-smoke.sh|\
scripts/build-app.sh|\
scripts/check-agent-app-release-claims.sh|\
scripts/check-mac-live-evidence.sh|\
scripts/check-real-mobile-evidence.sh|\
scripts/mac-distribution-docs-audit.sh|\
scripts/mac-install-upgrade-smoke.sh|\
scripts/mac-live-evidence-recorder-smoke.sh|\
scripts/mac-release-preflight.sh|\
scripts/mobile-evidence-recorder-smoke.sh|\
scripts/record-mac-live-evidence.sh|\
scripts/release-readiness.sh|\
tests/e2e/signed-screen.spec.ts)
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

  evidence_commit="$(git -C "$REPO_DIR" rev-parse --verify "${commit}^{commit}" 2>/dev/null)" || return 1
  required_commit="$(git -C "$REPO_DIR" rev-parse --verify "${REQUIRED_COMMIT}^{commit}" 2>/dev/null)" || return 1
  git -C "$REPO_DIR" merge-base --is-ancestor "$evidence_commit" "$required_commit" || return 1

  while IFS= read -r changed_path; do
    [[ -n "$changed_path" ]] || continue
    is_agent_evidence_neutral_path "$changed_path" || return 1
  done < <(git -C "$REPO_DIR" diff --name-only "$evidence_commit..$required_commit" --)

  return 0
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

has_release_evidence() {
  local app="$1"
  local key="$2"
  local file

  shopt -s nullglob
  for file in "$EVIDENCE_DIR"/"$key"-*.md; do
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

echo "Agent-app release-claim check"
echo "Matrix: $MATRIX_FILE"
echo "Evidence directory: $EVIDENCE_DIR"
echo "Required commit: $REQUIRED_COMMIT"
echo

if [[ ! -f "$MATRIX_FILE" ]]; then
  echo "Missing support matrix: $MATRIX_FILE" >&2
  exit 1
fi

if [[ ! -d "$EVIDENCE_DIR" ]]; then
  echo "Missing evidence directory: $EVIDENCE_DIR" >&2
  exit 1
fi

while IFS='|' read -r _ app support status release_ready risk _rest; do
  app="$(trim "$app")"
  status="$(trim "$status")"
  release_ready="$(trim "$release_ready")"

  [[ -n "$app" ]] || continue
  [[ "$app" == "App / Feature" || "$app" == "---" ]] && continue

  if [[ "$status" == "Release-ready" || "$release_ready" == "Yes" || "$release_ready" == "Release-ready" ]]; then
    key="$(slugify "$app")"
    if has_release_evidence "$app" "$key"; then
      printf '%-24s pass\n' "$app"
    else
      printf '%-24s missing evidence\n' "$app"
      echo "Missing matching pass evidence for release-ready app: $app ($key-*.md)" >&2
      FAILURES=$((FAILURES + 1))
    fi
  fi
done < <(
  awk '
    /^## Support Summary$/ { in_summary = 1; next }
    in_summary && /^## / { exit }
    in_summary && /^\|/ { print }
  ' "$MATRIX_FILE"
)

if [[ "$FAILURES" -gt 0 ]]; then
  echo >&2
  echo "Agent-app release-ready claims are missing required evidence." >&2
  exit 1
fi

echo "Agent-app release-ready claims are evidence-backed."
