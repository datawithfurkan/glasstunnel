#!/usr/bin/env bash
# Exercise notarization success and rejection handling without contacting Apple.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
BIN_DIR="$TMP_DIR/bin"
DMG_PATH="$TMP_DIR/Glasstunnel-9.8.7.dmg"
IDENTITY="Developer ID Application: Glasstunnel Test (ABCDE12345)"
EVENTS="$TMP_DIR/events.log"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "Mac notarization smoke failed: $*" >&2
  exit 1
}

mkdir -p "$BIN_DIR"
printf 'fake signed dmg\n' >"$DMG_PATH"

if bash "$ROOT_DIR/scripts/build-app.sh" --ad-hoc 9.8.7-beta \
  >"$TMP_DIR/invalid-version.log" 2>&1; then
  fail "packaging accepted a prerelease CFBundleShortVersionString"
fi
grep -Fq "Invalid release version: 9.8.7-beta" "$TMP_DIR/invalid-version.log" ||
  fail "packaging did not explain the invalid release version"

cat >"$BIN_DIR/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GT_SMOKE_EVENTS"
if [[ "$1" == "notarytool" && ( "$2" == "submit" || "$2" == "wait" ) ]]; then
  response="$(cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>id</key><string>11111111-2222-3333-4444-555555555555</string>
${GT_SMOKE_STATUS_ELEMENT:-<key>status</key><string>${GT_SMOKE_NOTARY_STATUS:-Accepted}</string>}
</dict></plist>
PLIST
  )"
  if [[ "${GT_SMOKE_RESPONSE_STREAM:-stdout}" == "stderr" ]]; then
    printf '%s\n' "$response" >&2
  else
    printf '%s\n' "$response"
  fi
  exit "${GT_SMOKE_SUBMIT_EXIT:-0}"
fi
if [[ "$1" == "notarytool" && "$2" == "log" ]]; then
  output_path="$4"
  printf '{"id":"11111111-2222-3333-4444-555555555555","status":"%s","sha256":"%s","issues":%s}\n' \
    "${GT_SMOKE_NOTARY_STATUS:-Accepted}" \
    "${GT_SMOKE_LOG_SHA:-$GT_SMOKE_DMG_SHA}" \
    "${GT_SMOKE_LOG_ISSUES:-[]}" >"$output_path"
  exit 0
fi
exit 0
SH

cat >"$BIN_DIR/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'codesign %s\n' "$*" >>"$GT_SMOKE_EVENTS"
if [[ "$1" == "-dvvv" ]]; then
  printf 'Authority=%s\nTeamIdentifier=ABCDE12345\n' "$GT_DEVELOPER_ID" >&2
fi
SH

cat >"$BIN_DIR/hdiutil" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'hdiutil %s\n' "$*" >>"$GT_SMOKE_EVENTS"
if [[ "$1" == "attach" ]]; then
  mountpoint=""
  previous=""
  for argument in "$@"; do
    if [[ "$previous" == "-mountpoint" ]]; then
      mountpoint="$argument"
      break
    fi
    previous="$argument"
  done
  mkdir -p "$mountpoint/Glasstunnel.app/Contents/Frameworks/WebRTC.framework"
fi
SH

cat >"$BIN_DIR/spctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'spctl %s\n' "$*" >>"$GT_SMOKE_EVENTS"
SH

chmod +x "$BIN_DIR/xcrun" "$BIN_DIR/codesign" "$BIN_DIR/hdiutil" "$BIN_DIR/spctl"

run_notarization() {
  PATH="$BIN_DIR:$PATH" \
    GT_DEVELOPER_ID="$IDENTITY" \
    GT_NOTARY_PROFILE="test-profile" \
    GT_NOTARY_EVIDENCE_DIR="$TMP_DIR/evidence" \
    GT_SMOKE_EVENTS="$EVENTS" \
    GT_SMOKE_NOTARY_STATUS="${1:-Accepted}" \
    GT_SMOKE_SUBMIT_EXIT="${2:-0}" \
    GT_SMOKE_LOG_ISSUES="${3:-[]}" \
    GT_NOTARY_SUBMISSION_ID="${4:-}" \
    GT_SMOKE_RESPONSE_STREAM="${6:-stdout}" \
    GT_SMOKE_STATUS_ELEMENT="${7:-}" \
    GT_SMOKE_DMG_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')" \
    GT_SMOKE_LOG_SHA="${5:-}" \
    bash "$ROOT_DIR/scripts/notarize-mac-release.sh" "$DMG_PATH"
}

run_notarization Accepted >"$TMP_DIR/success.log"

[[ -s "$TMP_DIR/evidence/Glasstunnel-9.8.7-notary-submit.plist" ]] ||
  fail "accepted run did not retain the submission response"
[[ -s "$TMP_DIR/evidence/Glasstunnel-9.8.7-notary-log.json" ]] ||
  fail "accepted run did not retain Apple's log"

for expected in \
  "notarytool submit" \
  "notarytool log" \
  "stapler staple" \
  "stapler validate" \
  "spctl --assess --type open" \
  "hdiutil attach" \
  "spctl --assess --type execute"; do
  grep -Fq "$expected" "$EVENTS" || fail "accepted run did not execute: $expected"
done

: >"$EVENTS"
if run_notarization Invalid >"$TMP_DIR/rejected.log" 2>&1; then
  fail "an Invalid Apple status was accepted"
fi
grep -Fq "notarytool log" "$EVENTS" ||
  fail "rejected run did not retrieve Apple's diagnostic log"
if grep -Fq "stapler staple" "$EVENTS"; then
  fail "rejected run attempted to staple the DMG"
fi

: >"$EVENTS"
if run_notarization Accepted 1 >"$TMP_DIR/submit-failure.log" 2>&1; then
  fail "a non-zero notarytool submit result was accepted"
fi
grep -Fq "notarytool log" "$EVENTS" ||
  fail "non-zero submit run did not retrieve Apple's diagnostic log"
if grep -Fq "stapler staple" "$EVENTS"; then
  fail "non-zero submit run attempted to staple the DMG"
fi

: >"$EVENTS"
if run_notarization Accepted 1 '[]' '' '' stderr '<key>message</key><string>Timeout reached.</string>' \
  >"$TMP_DIR/timeout-stderr.log" 2>&1; then
  fail "a timed-out notarytool response was accepted"
fi
grep -Fq "GT_NOTARY_SUBMISSION_ID=11111111-2222-3333-4444-555555555555" \
  "$TMP_DIR/timeout-stderr.log" ||
  fail "stderr timeout response did not preserve the resumable submission ID"
[[ -s "$TMP_DIR/evidence/Glasstunnel-9.8.7-notary-submit.plist" ]] ||
  fail "stderr timeout response did not retain the submission response"
if grep -Fq "notarytool log" "$EVENTS"; then
  fail "in-progress timeout run attempted to download an unavailable log"
fi

: >"$EVENTS"
if run_notarization Accepted 0 '[{"message":"unexpected warning"}]' \
  >"$TMP_DIR/log-issue.log" 2>&1; then
  fail "an Apple log containing issues was accepted"
fi
if grep -Fq "stapler staple" "$EVENTS"; then
  fail "log-issue run attempted to staple the DMG"
fi

: >"$EVENTS"
run_notarization Accepted 0 '[]' "11111111-2222-3333-4444-555555555555" \
  >"$TMP_DIR/resume.log"
grep -Fq "notarytool wait 11111111-2222-3333-4444-555555555555" "$EVENTS" ||
  fail "resume run did not wait on the existing Apple submission"
if grep -Fq "notarytool submit" "$EVENTS"; then
  fail "resume run uploaded a duplicate Apple submission"
fi

: >"$EVENTS"
run_notarization Accepted 0 'null' >"$TMP_DIR/null-issues.log"
grep -Fq "stapler validate" "$EVENTS" ||
  fail "Accepted Apple log with null issues did not complete verification"

: >"$EVENTS"
if run_notarization Accepted 0 '[]' \
  "11111111-2222-3333-4444-555555555555" \
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  >"$TMP_DIR/mismatched-artifact.log" 2>&1; then
  fail "resume accepted an Apple log for a different artifact"
fi
if grep -Fq "stapler staple" "$EVENTS"; then
  fail "mismatched-artifact run attempted to staple the DMG"
fi

echo "Mac notarization smoke passed."
