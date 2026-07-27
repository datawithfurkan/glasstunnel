#!/usr/bin/env bash
# Verify that physical-phone mobile QA evidence has been recorded.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${GT_REAL_MOBILE_REPO_DIR:-$ROOT_DIR}"
EVIDENCE_DIR="${GT_REAL_MOBILE_EVIDENCE_DIR:-$ROOT_DIR/docs/release-evidence/mobile}"
REQUIRED_SCOPES="${GT_REAL_MOBILE_REQUIRED_SCOPES:-release-smoke screen-sharing}"
REQUIRED_BROWSERS="${GT_REAL_MOBILE_REQUIRED_BROWSERS:-Safari Chrome}"
REQUIRED_COMMIT="${GT_REAL_MOBILE_REQUIRED_COMMIT:-$(git -C "$REPO_DIR" rev-parse --short HEAD)}"
FAILURES=0
STALE_RECORDS=()
INVALID_RECORDS=()

usage() {
  cat <<'USAGE'
Usage: bash scripts/check-real-mobile-evidence.sh

Checks docs/release-evidence/mobile for physical-phone QA pass records.
Default release requirements:
  - browsers: Safari Chrome
  - scopes: release-smoke screen-sharing

Environment:
  GT_REAL_MOBILE_EVIDENCE_DIR       Override evidence directory.
  GT_REAL_MOBILE_REPO_DIR           Override the Git repository used for evidence ancestry.
  GT_REAL_MOBILE_REQUIRED_BROWSERS  Space-separated browsers. Default: "Safari Chrome".
  GT_REAL_MOBILE_REQUIRED_SCOPES    Space-separated scopes. Default: "release-smoke screen-sharing".
  GT_REAL_MOBILE_REQUIRED_COMMIT    Commit prefix records must match. Defaults to current HEAD.
                                      Ancestor records are accepted only when
                                      later commits changed docs/evidence/checker
                                      files, not product code.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

artifact_path_for_record() {
  local file="$1"
  local line

  line="$(grep -m1 -E '^- Screenshot or recording: ' "$file" || true)"
  printf '%s' "${line#- Screenshot or recording: }"
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
    [[ -s "$artifact" ]]
    return
  fi

  evidence_relative="$(dirname "$file")/$artifact"
  [[ -s "$evidence_relative" || -s "$ROOT_DIR/$artifact" ]]
}

field_value_for_record() {
  local file="$1"
  local field="$2"
  local line

  line="$(grep -m1 -E "^- $field: " "$file" || true)"
  printf '%s' "${line#- $field: }"
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
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

has_terminal_session_controls_checklist() {
  local file="$1"
  local passed

  passed="$(normalized_lowercase "$(section_text_for_record "$file" "Passed")")"

  [[ "$passed" == *open* && "$passed" == *terminal* ]] || return 1
  [[ "$passed" == *command* && ( "$passed" == *output* || "$passed" == *marker* ) ]] || return 1
  [[ "$passed" == *interrupt* || "$passed" == *stop* ]] || return 1
  [[ "$passed" == *"terminal 2"* || "$passed" == *"new session"* || "$passed" == *"fresh session"* ]] || return 1
  [[ "$passed" == *"default terminal"* && ( "$passed" == *switch* || "$passed" == *return* || "$passed" == *back* || "$passed" == *resume* ) ]] || return 1
  [[ "$passed" == *rename* ]] || return 1
  [[ "$passed" == *"terminal 2"* && "$passed" == *close* ]] || return 1
  [[ "$passed" == *default* && "$passed" == *close* ]] || return 1
}

is_physical_phone_record() {
  local file="$1"
  local phone
  local phone_os

  phone="$(lowercase "$(field_value_for_record "$file" "Phone")")"
  phone_os="$(lowercase "$(field_value_for_record "$file" "Phone OS")")"

  [[ -n "$phone" && -n "$phone_os" ]] || return 1
  [[ "$phone" != *simulator* && "$phone_os" != *simulator* ]]
}

record_matches_required_commit() {
  local file="$1"
  local commit

  commit="$(field_value_for_record "$file" "Glasstunnel commit")"

  [[ -n "$commit" && -n "$REQUIRED_COMMIT" ]] || return 1
  if [[ "$commit" == "$REQUIRED_COMMIT"* || "$REQUIRED_COMMIT" == "$commit"* ]]; then
    return 0
  fi

  only_non_product_changes_since_record "$commit" "$REQUIRED_COMMIT"
}

is_product_path() {
  case "$1" in
    apps/*|packages/*|site/*|supabase/*|Casks/*|deploy/*|package.json|pnpm-lock.yaml|pnpm-workspace.yaml|Makefile|Dockerfile*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_allowed_evidence_path() {
  case "$1" in
    docs/*|AGENTS.md|DESIGN.md|README.md|CONTRIBUTING.md|SECURITY.md|LICENSE|\
scripts/check-real-mobile-evidence.sh|scripts/mobile-evidence-recorder-smoke.sh|scripts/record-real-mobile-qa.sh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

only_non_product_changes_since_record() {
  local record_commit="$1"
  local required_commit="$2"
  local record_rev
  local required_rev
  local changed
  local path

  record_rev="$(git -C "$REPO_DIR" rev-parse --verify --quiet "${record_commit}^{commit}" || true)"
  required_rev="$(git -C "$REPO_DIR" rev-parse --verify --quiet "${required_commit}^{commit}" || true)"
  [[ -n "$record_rev" && -n "$required_rev" ]] || return 1

  git -C "$REPO_DIR" merge-base --is-ancestor "$record_rev" "$required_rev" || return 1

  changed="$(git -C "$REPO_DIR" diff --name-only "$record_rev..$required_rev")"
  [[ -n "$changed" ]] || return 0

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if is_product_path "$path" || ! is_allowed_evidence_path "$path"; then
      return 1
    fi
  done <<< "$changed"
}

has_pass_record() {
  local browser="$1"
  local scope="$2"
  local file
  local artifact

  shopt -s nullglob
  for file in "$EVIDENCE_DIR"/*.md; do
    if grep -Fqx -- "- Browser: $browser" "$file" \
      && grep -Fqx -- "- Scope: $scope" "$file" \
      && grep -Fqx -- "- Result: pass" "$file"; then
      if ! is_physical_phone_record "$file"; then
        INVALID_RECORDS+=("$browser $scope: $file is not physical-phone evidence")
        continue
      fi
      if ! record_matches_required_commit "$file"; then
        INVALID_RECORDS+=("$browser $scope: $file does not match required commit $REQUIRED_COMMIT")
        continue
      fi
      if ! has_meaningful_passed_section "$file"; then
        INVALID_RECORDS+=("$browser $scope: $file has no meaningful Passed checklist")
        continue
      fi
      if [[ "$scope" == "terminal-session-controls" ]] && ! has_terminal_session_controls_checklist "$file"; then
        INVALID_RECORDS+=("$browser $scope: $file does not document the full Terminal session-control journey")
        continue
      fi
      if artifact_exists_for_record "$file"; then
        shopt -u nullglob
        return 0
      fi
      artifact="$(artifact_path_for_record "$file")"
      STALE_RECORDS+=("$browser $scope: $file references missing screenshot or recording: ${artifact:-not recorded}")
    fi
  done
  shopt -u nullglob

  return 1
}

echo "Real mobile evidence check"
echo "Evidence directory: $EVIDENCE_DIR"
echo "Required browsers: $REQUIRED_BROWSERS"
echo "Required scopes: $REQUIRED_SCOPES"
echo "Required commit: $REQUIRED_COMMIT"
echo

if [[ ! -d "$EVIDENCE_DIR" ]]; then
  echo "Missing evidence directory: $EVIDENCE_DIR" >&2
  exit 1
fi

for browser in $REQUIRED_BROWSERS; do
  for scope in $REQUIRED_SCOPES; do
    if has_pass_record "$browser" "$scope"; then
      printf '%-28s pass\n' "$browser $scope"
    else
      printf '%-28s missing\n' "$browser $scope"
      FAILURES=$((FAILURES + 1))
    fi
  done
done

echo
if [[ "$FAILURES" -gt 0 ]]; then
  if [[ "${#INVALID_RECORDS[@]}" -gt 0 ]]; then
    echo "Invalid pass records:" >&2
    for record in "${INVALID_RECORDS[@]}"; do
      echo "  - $record" >&2
    done
  fi
  if [[ "${#STALE_RECORDS[@]}" -gt 0 ]]; then
    echo "Stale or incomplete pass records:" >&2
    for record in "${STALE_RECORDS[@]}"; do
      echo "  - $record" >&2
    done
  fi
  echo "Real-phone mobile evidence is incomplete." >&2
  echo "Record evidence with pnpm qa:mobile:real after testing on a physical phone." >&2
  exit 1
fi

echo "Real-phone mobile evidence is complete."
