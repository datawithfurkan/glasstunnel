#!/usr/bin/env bash
# Record real-phone mobile QA evidence without treating simulator output as a
# public-release mobile-browser pass.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_REAL_MOBILE_EVIDENCE_DIR:-$ROOT_DIR/.cache/glasstunnel-evidence/mobile}"
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: pnpm qa:mobile:real [--dry-run]

Records raw real-phone QA under ignored .cache/glasstunnel-evidence/mobile.
This script does not run the test. Run the flow on an actual phone first, then
record the evidence with the environment variables below.

Review and redact the result before manually creating a concise public summary
under docs/release-evidence. Never commit this script's raw output directly.

Required environment:
  GT_REAL_MOBILE_BROWSER     Safari or Chrome
  GT_REAL_MOBILE_RESULT      pass or fail
  GT_REAL_MOBILE_SCOPE       auth, workspace, screen-sharing, codex, cursor,
                              terminal, terminal-session-controls, or
                              release-smoke
  GT_REAL_MOBILE_DEVICE      Physical phone model, for example "iPhone 15 Pro"
  GT_REAL_MOBILE_OS          Phone OS version, for example "iOS 18.5"
  GT_REAL_MOBILE_MAC         Redacted Mac label, for example "test Mac"
  GT_REAL_MOBILE_MACOS       Mac OS version, for example "macOS 15.5"
  GT_REAL_MOBILE_SCREENSHOT  Local screenshot or screen-recording path

Optional environment:
  GT_REAL_MOBILE_EVIDENCE_DIR Override evidence directory.
  GT_REAL_MOBILE_URL         URL tested. Defaults to https://app.glasstunnel.io
  GT_REAL_MOBILE_ACCOUNT     Redacted account label, for example "primary test account"
  GT_REAL_MOBILE_COMMIT      Commit tested. Defaults to current git commit.
  GT_REAL_MOBILE_PASSED      Short passed checklist.
  GT_REAL_MOBILE_FAILED      Short failed checklist.
  GT_REAL_MOBILE_NOTES       Short notes or follow-up issue refs.

For pass results, GT_REAL_MOBILE_SCREENSHOT must point to an existing file.
For pass results, GT_REAL_MOBILE_PASSED must summarize the behavior that
actually passed.
Use --dry-run to print the record without writing a file.
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
  GT_REAL_MOBILE_BROWSER \
  GT_REAL_MOBILE_RESULT \
  GT_REAL_MOBILE_SCOPE \
  GT_REAL_MOBILE_DEVICE \
  GT_REAL_MOBILE_OS \
  GT_REAL_MOBILE_MAC \
  GT_REAL_MOBILE_MACOS \
  GT_REAL_MOBILE_SCREENSHOT; do
  require_env "$name"
done

BROWSER="$GT_REAL_MOBILE_BROWSER"
RESULT="$GT_REAL_MOBILE_RESULT"
SCOPE="$GT_REAL_MOBILE_SCOPE"
SCREENSHOT="$GT_REAL_MOBILE_SCREENSHOT"
URL="${GT_REAL_MOBILE_URL:-https://app.glasstunnel.io}"
ACCOUNT="${GT_REAL_MOBILE_ACCOUNT:-redacted test account}"
COMMIT="${GT_REAL_MOBILE_COMMIT:-$(git -C "$ROOT_DIR" rev-parse --short HEAD)}"
PASSED="${GT_REAL_MOBILE_PASSED:-Not recorded.}"
FAILED="${GT_REAL_MOBILE_FAILED:-Not recorded.}"
NOTES="${GT_REAL_MOBILE_NOTES:-None.}"

case "$BROWSER" in
  Safari|Chrome) ;;
  *)
    echo "GT_REAL_MOBILE_BROWSER must be Safari or Chrome." >&2
    exit 1
    ;;
esac

case "$RESULT" in
  pass|fail) ;;
  *)
    echo "GT_REAL_MOBILE_RESULT must be pass or fail." >&2
    exit 1
    ;;
esac

case "$SCOPE" in
  auth|workspace|screen-sharing|codex|cursor|terminal|terminal-session-controls|release-smoke) ;;
  *)
    echo "GT_REAL_MOBILE_SCOPE must be auth, workspace, screen-sharing, codex, cursor, terminal, terminal-session-controls, or release-smoke." >&2
    exit 1
    ;;
esac

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

normalized_lowercase() {
  printf '%s' "$1" | tr '\n' ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' | tr '[:upper:]' '[:lower:]'
}

if [[ "$RESULT" == "pass" ]]; then
  DEVICE_LOWER="$(lowercase "$GT_REAL_MOBILE_DEVICE")"
  OS_LOWER="$(lowercase "$GT_REAL_MOBILE_OS")"
  if [[ "$DEVICE_LOWER" == *simulator* || "$OS_LOWER" == *simulator* ]]; then
    echo "Pass results must come from a physical phone, not an iOS Simulator." >&2
    exit 1
  fi
fi

if [[ "$RESULT" == "pass" && ! -s "$SCREENSHOT" ]]; then
  echo "GT_REAL_MOBILE_SCREENSHOT must point to an existing non-empty file for pass results." >&2
  exit 1
fi

if [[ "$RESULT" == "pass" ]]; then
  case "$(normalized_lowercase "$PASSED")" in
    ""|"not recorded."|"none."|"n/a"|"na")
      echo "GT_REAL_MOBILE_PASSED must summarize what passed for pass results." >&2
      exit 1
      ;;
  esac
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
SAFE_BROWSER="$(printf '%s' "$BROWSER" | tr '[:upper:] ' '[:lower:]-')"
SAFE_SCOPE="$(printf '%s' "$SCOPE" | tr '[:upper:] ' '[:lower:]-')"
OUT_FILE="$OUT_DIR/$STAMP-$SAFE_BROWSER-$SAFE_SCOPE-$RESULT.md"
RECORDED_SCREENSHOT="$SCREENSHOT"

copy_artifact() {
  local source="$1"
  local artifact_dir="$OUT_DIR/artifacts"
  local base
  local safe_base
  local dest

  [[ -e "$source" ]] || return 0

  base="$(basename "$source")"
  safe_base="$(printf '%s' "$base" | tr -c '[:alnum:]._-' '-')"
  dest="$artifact_dir/$STAMP-$SAFE_BROWSER-$SAFE_SCOPE-$RESULT-$safe_base"

  mkdir -p "$artifact_dir"
  cp "$source" "$dest"
  RECORDED_SCREENSHOT="artifacts/$(basename "$dest")"
}

if [[ "$DRY_RUN" != "1" ]]; then
  copy_artifact "$SCREENSHOT"
fi

RECORD="$(cat <<EOF
# Real Mobile QA Evidence

- Date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
- Scope: $SCOPE
- Result: $RESULT
- Browser: $BROWSER
- Phone: $GT_REAL_MOBILE_DEVICE
- Phone OS: $GT_REAL_MOBILE_OS
- Mac: $GT_REAL_MOBILE_MAC
- macOS: $GT_REAL_MOBILE_MACOS
- Glasstunnel commit: $COMMIT
- URL: $URL
- Test account: $ACCOUNT
- Screenshot or recording: $RECORDED_SCREENSHOT

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
  echo "Real mobile QA evidence: $OUT_FILE"
fi
