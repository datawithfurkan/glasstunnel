#!/usr/bin/env bash
# Record live Mac app release evidence for permission, auth, and relaunch gates.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_MAC_LIVE_EVIDENCE_DIR:-$ROOT_DIR/.cache/glasstunnel-evidence/mac-app}"
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: pnpm qa:mac:live [--dry-run]

Records raw live Mac QA under ignored .cache/glasstunnel-evidence/mac-app.
This script does not run the test. Run the bundled app flow first, then record
the evidence with the environment variables below.

Review and redact the result before manually creating a concise public summary
under docs/release-evidence. Never commit this script's raw output directly.

Required environment:
  GT_MAC_LIVE_SCOPE         permission-onboarding, auth-relaunch, install-upgrade, or release-smoke
  GT_MAC_LIVE_RESULT        pass or fail
  GT_MAC_LIVE_MAC           Redacted Mac label, for example "test Mac"
  GT_MAC_LIVE_MACOS         macOS version, for example "macOS 15.5"
  GT_MAC_LIVE_APP_VERSION   Glasstunnel app version/build
  GT_MAC_LIVE_BUNDLE_ID     Bundle ID tested, for example "io.glasstunnel.host"
  GT_MAC_LIVE_INSTALL_PATH  App path tested, for example "/Applications/Glasstunnel.app"
  GT_MAC_LIVE_ARTIFACT      Local screenshot, recording, or log artifact path

Optional environment:
  GT_MAC_LIVE_EVIDENCE_DIR  Override evidence directory.
  GT_MAC_LIVE_ACCOUNT       Redacted account label, for example "primary test account"
  GT_MAC_LIVE_COMMIT        Commit tested. Defaults to current git commit.
  GT_MAC_LIVE_PASSED        Short passed checklist. Required for pass results.
  GT_MAC_LIVE_FAILED        Short failed checklist.
  GT_MAC_LIVE_NOTES         Short notes or follow-up issue refs.
  GT_MAC_LIVE_PRIVACY_REVIEW Set to pass only after reviewing the record and
                             copied artifact. Defaults to pending.

For pass results, GT_MAC_LIVE_ARTIFACT must point to an existing file.
For pass results, GT_MAC_LIVE_PASSED must summarize the behavior that actually
passed. Use --dry-run to print the record without writing a file.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --)
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "$name is required." >&2
    exit 1
  fi
}

for name in \
  GT_MAC_LIVE_SCOPE \
  GT_MAC_LIVE_RESULT \
  GT_MAC_LIVE_MAC \
  GT_MAC_LIVE_MACOS \
  GT_MAC_LIVE_APP_VERSION \
  GT_MAC_LIVE_BUNDLE_ID \
  GT_MAC_LIVE_INSTALL_PATH \
  GT_MAC_LIVE_ARTIFACT; do
  require_env "$name"
done

SCOPE="$GT_MAC_LIVE_SCOPE"
RESULT="$GT_MAC_LIVE_RESULT"
ARTIFACT="$GT_MAC_LIVE_ARTIFACT"
ACCOUNT="${GT_MAC_LIVE_ACCOUNT:-redacted test account}"
COMMIT="${GT_MAC_LIVE_COMMIT:-$(git -C "$ROOT_DIR" rev-parse --short HEAD)}"
PASSED="${GT_MAC_LIVE_PASSED:-Not recorded.}"
FAILED="${GT_MAC_LIVE_FAILED:-Not recorded.}"
NOTES="${GT_MAC_LIVE_NOTES:-None.}"
PRIVACY_REVIEW="${GT_MAC_LIVE_PRIVACY_REVIEW:-pending}"

case "$SCOPE" in
  permission-onboarding|auth-relaunch|install-upgrade|release-smoke) ;;
  *)
    echo "GT_MAC_LIVE_SCOPE must be permission-onboarding, auth-relaunch, install-upgrade, or release-smoke." >&2
    exit 1
    ;;
esac

case "$RESULT" in
  pass|fail) ;;
  *)
    echo "GT_MAC_LIVE_RESULT must be pass or fail." >&2
    exit 1
    ;;
esac

case "$PRIVACY_REVIEW" in
  pending|pass) ;;
  *)
    echo "GT_MAC_LIVE_PRIVACY_REVIEW must be pending or pass." >&2
    exit 1
    ;;
esac

normalized_lowercase() {
  printf '%s' "$1" | tr '\n' ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' | tr '[:upper:]' '[:lower:]'
}

if [[ "$RESULT" == "pass" && ! -e "$ARTIFACT" ]]; then
  echo "GT_MAC_LIVE_ARTIFACT must point to an existing file for pass results." >&2
  exit 1
fi

if [[ "$RESULT" == "pass" ]]; then
  case "$(normalized_lowercase "$PASSED")" in
    ""|"not recorded."|"none."|"n/a"|"na")
      echo "GT_MAC_LIVE_PASSED must summarize what passed for pass results." >&2
      exit 1
      ;;
  esac
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
SAFE_SCOPE="$(printf '%s' "$SCOPE" | tr '[:upper:] ' '[:lower:]-')"
OUT_FILE="$OUT_DIR/$STAMP-$SAFE_SCOPE-$RESULT.md"
RECORDED_ARTIFACT="$ARTIFACT"

copy_artifact() {
  local source="$1"
  local artifact_dir="$OUT_DIR/artifacts"
  local base
  local safe_base
  local dest

  [[ -e "$source" ]] || return 0

  base="$(basename "$source")"
  safe_base="$(printf '%s' "$base" | tr -c '[:alnum:]._-' '-')"
  if [[ "$safe_base" == *.log ]]; then
    safe_base="${safe_base%.log}.txt"
  fi
  dest="$artifact_dir/$STAMP-$SAFE_SCOPE-$RESULT-$safe_base"

  mkdir -p "$artifact_dir"
  cp "$source" "$dest"
  RECORDED_ARTIFACT="artifacts/$(basename "$dest")"
}

if [[ "$DRY_RUN" != "1" ]]; then
  copy_artifact "$ARTIFACT"
fi

RECORD="$(cat <<EOF
# Mac Live QA Evidence

- Date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
- Scope: $SCOPE
- Result: $RESULT
- Mac: $GT_MAC_LIVE_MAC
- macOS: $GT_MAC_LIVE_MACOS
- Glasstunnel commit: $COMMIT
- App version: $GT_MAC_LIVE_APP_VERSION
- Bundle ID: $GT_MAC_LIVE_BUNDLE_ID
- Install path: $GT_MAC_LIVE_INSTALL_PATH
- Test account: $ACCOUNT
- Artifact: $RECORDED_ARTIFACT
- Privacy review: $PRIVACY_REVIEW

## Passed

$PASSED

## Failed

$FAILED

## Notes

$NOTES
EOF
)"

if [[ "$DRY_RUN" == "1" ]]; then
  printf '%s\n' "$RECORD"
else
  mkdir -p "$OUT_DIR"
  printf '%s\n' "$RECORD" > "$OUT_FILE"
  echo "Mac live QA evidence: $OUT_FILE"
fi
