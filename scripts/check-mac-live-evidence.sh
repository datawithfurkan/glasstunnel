#!/usr/bin/env bash
# Verify that live Mac app release evidence has been recorded.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_DIR="${GT_MAC_LIVE_EVIDENCE_DIR:-$ROOT_DIR/docs/release-evidence/mac-app}"
REQUIRED_SCOPES="${GT_MAC_LIVE_REQUIRED_SCOPES:-permission-onboarding auth-relaunch}"
REQUIRED_COMMIT="${GT_MAC_LIVE_REQUIRED_COMMIT:-$(git -C "$ROOT_DIR" rev-parse --short HEAD)}"
FAILURES=0
INVALID_RECORDS=()
STALE_RECORDS=()

usage() {
  cat <<'USAGE'
Usage: bash scripts/check-mac-live-evidence.sh

Checks docs/release-evidence/mac-app for live Mac app pass records.
Default release requirements:
  - scopes: permission-onboarding auth-relaunch

Environment:
  GT_MAC_LIVE_EVIDENCE_DIR      Override evidence directory.
  GT_MAC_LIVE_REQUIRED_SCOPES   Space-separated scopes.
  GT_MAC_LIVE_REQUIRED_COMMIT   Commit prefix records must match. Defaults to current HEAD.
                                  Ancestor records are accepted only when later
                                  commits did not change Mac live evidence
                                  surfaces such as the Mac host, protocol, or
                                  build and launch scripts.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

field_value_for_record() {
  local file="$1"
  local field="$2"
  local line

  line="$(grep -m1 -E "^- $field: " "$file" || true)"
  printf '%s' "${line#- $field: }"
}

artifact_path_for_record() {
  field_value_for_record "$1" "Artifact"
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

is_mac_live_invalidating_path() {
  case "$1" in
    apps/host-macos/*|\
packages/protocol/*|\
scripts/build-app.sh|\
scripts/dev-app.sh|\
scripts/lab/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

no_mac_live_invalidating_changes_since_record() {
  local record_commit="$1"
  local required_commit="$2"
  local record_rev
  local required_rev
  local changed
  local path

  record_rev="$(git -C "$ROOT_DIR" rev-parse --verify --quiet "${record_commit}^{commit}" || true)"
  required_rev="$(git -C "$ROOT_DIR" rev-parse --verify --quiet "${required_commit}^{commit}" || true)"
  [[ -n "$record_rev" && -n "$required_rev" ]] || return 1

  git -C "$ROOT_DIR" merge-base --is-ancestor "$record_rev" "$required_rev" || return 1

  changed="$(git -C "$ROOT_DIR" diff --name-only "$record_rev..$required_rev")"
  [[ -n "$changed" ]] || return 0

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if is_mac_live_invalidating_path "$path"; then
      return 1
    fi
  done <<< "$changed"
}

record_matches_required_commit() {
  local file="$1"
  local commit

  commit="$(field_value_for_record "$file" "Glasstunnel commit")"

  [[ -n "$commit" && -n "$REQUIRED_COMMIT" ]] || return 1
  if [[ "$commit" == "$REQUIRED_COMMIT"* || "$REQUIRED_COMMIT" == "$commit"* ]]; then
    return 0
  fi

  no_mac_live_invalidating_changes_since_record "$commit" "$REQUIRED_COMMIT"
}

has_pass_record() {
  local scope="$1"
  local file
  local artifact

  shopt -s nullglob
  for file in "$EVIDENCE_DIR"/*.md; do
    if grep -Fqx -- "- Scope: $scope" "$file" \
      && grep -Fqx -- "- Result: pass" "$file"; then
      if ! record_matches_required_commit "$file"; then
        INVALID_RECORDS+=("$scope: $file does not match required commit $REQUIRED_COMMIT")
        continue
      fi
      if ! has_meaningful_passed_section "$file"; then
        INVALID_RECORDS+=("$scope: $file has no meaningful Passed checklist")
        continue
      fi
      if ! has_privacy_review "$file"; then
        INVALID_RECORDS+=("$scope: $file has no completed privacy review")
        continue
      fi
      if artifact_exists_for_record "$file"; then
        shopt -u nullglob
        return 0
      fi
      artifact="$(artifact_path_for_record "$file")"
      STALE_RECORDS+=("$scope: $file references missing artifact: ${artifact:-not recorded}")
    fi
  done
  shopt -u nullglob

  return 1
}

echo "Mac live evidence check"
echo "Evidence directory: $EVIDENCE_DIR"
echo "Required scopes: $REQUIRED_SCOPES"
echo "Required commit: $REQUIRED_COMMIT"
echo

if [[ ! -d "$EVIDENCE_DIR" ]]; then
  echo "Missing evidence directory: $EVIDENCE_DIR" >&2
  exit 1
fi

for scope in $REQUIRED_SCOPES; do
  if has_pass_record "$scope"; then
    printf '%-28s pass\n' "$scope"
  else
    printf '%-28s missing\n' "$scope"
    FAILURES=$((FAILURES + 1))
  fi
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
  echo "Live Mac app evidence is incomplete." >&2
  echo "Record evidence with pnpm qa:mac:live after testing the bundled Mac app." >&2
  exit 1
fi

echo "Live Mac app evidence is complete."
