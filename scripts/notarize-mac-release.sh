#!/usr/bin/env bash
# Submit a Developer ID-signed DMG, retain Apple's log, staple it, and verify
# both the outer disk image and the app it contains through Gatekeeper.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_PATH="${1:-}"
APP_NAME="Glasstunnel.app"
NOTARY_PROFILE="${GT_NOTARY_PROFILE:-glasstunnel-notary}"
DEVELOPER_ID="${GT_DEVELOPER_ID:-}"
EVIDENCE_DIR="${GT_NOTARY_EVIDENCE_DIR:-$ROOT_DIR/dist/notarization}"
NOTARY_TIMEOUT="${GT_NOTARY_TIMEOUT:-30m}"
EXISTING_SUBMISSION_ID="${GT_NOTARY_SUBMISSION_ID:-}"

usage() {
  cat <<'USAGE'
Usage: bash scripts/notarize-mac-release.sh dist/Glasstunnel-VERSION.dmg

Requires a Developer ID-signed DMG and a working notarytool keychain profile.
The script stores Apple's submission response and notarization log under
dist/notarization/, staples and validates the DMG ticket, then requires
Gatekeeper to accept both the DMG and its mounted Glasstunnel.app.

Environment:
  GT_DEVELOPER_ID          Exact Developer ID Application identity.
  GT_NOTARY_PROFILE        notarytool keychain profile (default: glasstunnel-notary).
  GT_NOTARY_EVIDENCE_DIR   Optional output directory for Apple response files.
  GT_NOTARY_TIMEOUT        Maximum wait for Apple (default: 30m).
  GT_NOTARY_SUBMISSION_ID  Resume an existing submission instead of uploading again.
USAGE
}

if [[ "$DMG_PATH" == "-h" || "$DMG_PATH" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "$DMG_PATH" ]]; then
  usage >&2
  exit 2
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "Release DMG not found: $DMG_PATH" >&2
  exit 1
fi

if [[ "$DEVELOPER_ID" != "Developer ID Application: "* ]]; then
  echo "GT_DEVELOPER_ID must name the identity used to sign this release." >&2
  exit 1
fi

expected_team_id=""
if [[ "$DEVELOPER_ID" =~ [(]([A-Z0-9]+)[)]$ ]]; then
  expected_team_id="${BASH_REMATCH[1]}"
fi
if [[ -z "$expected_team_id" ]]; then
  echo "Could not read a team ID from GT_DEVELOPER_ID: $DEVELOPER_ID" >&2
  exit 1
fi

mkdir -p "$EVIDENCE_DIR"
dmg_filename="$(basename "$DMG_PATH")"
artifact_name="${dmg_filename%.dmg}"
submission_plist="$EVIDENCE_DIR/$artifact_name-notary-submit.plist"
submission_stdout="$submission_plist.stdout"
submission_stderr="$submission_plist.stderr"
notary_log="$EVIDENCE_DIR/$artifact_name-notary-log.json"
mount_root="$(mktemp -d "${TMPDIR:-/tmp}/glasstunnel-notary-mount.XXXXXX")"
attached=0

cleanup() {
  if [[ "$attached" == "1" ]]; then
    hdiutil detach "$mount_root" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$mount_root"
}
trap cleanup EXIT

require_developer_id_signature() {
  local path="$1"
  local context="$2"
  local details
  details="$(codesign -dvvv "$path" 2>&1)"
  if ! grep -Fq "Authority=$DEVELOPER_ID" <<<"$details"; then
    echo "$context is not signed by the configured Developer ID identity." >&2
    exit 1
  fi
  if ! grep -Fq "TeamIdentifier=$expected_team_id" <<<"$details"; then
    echo "$context does not carry expected team ID $expected_team_id." >&2
    exit 1
  fi
}

echo "==> Verifying Developer ID signature"
codesign --verify --strict --verbose=2 "$DMG_PATH"
require_developer_id_signature "$DMG_PATH" "Release DMG"
local_sha256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"

set +e
rm -f "$submission_plist" "$submission_stdout" "$submission_stderr"
if [[ -n "$EXISTING_SUBMISSION_ID" ]]; then
  echo "==> Resuming Apple notarization submission $EXISTING_SUBMISSION_ID"
  xcrun notarytool wait "$EXISTING_SUBMISSION_ID" \
    --keychain-profile "$NOTARY_PROFILE" \
    --timeout "$NOTARY_TIMEOUT" \
    --output-format plist >"$submission_stdout" 2>"$submission_stderr"
else
  echo "==> Submitting to Apple notary service"
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --timeout "$NOTARY_TIMEOUT" \
    --output-format plist >"$submission_stdout" 2>"$submission_stderr"
fi
submit_exit=$?
set -e

# notarytool writes successful plist responses to stdout, but timeout responses
# containing the resumable submission ID are emitted on stderr.
if [[ -s "$submission_stdout" ]] &&
  /usr/bin/plutil -p "$submission_stdout" >/dev/null 2>&1; then
  mv "$submission_stdout" "$submission_plist"
elif [[ -s "$submission_stderr" ]] &&
  /usr/bin/plutil -p "$submission_stderr" >/dev/null 2>&1; then
  mv "$submission_stderr" "$submission_plist"
else
  echo "Apple's submission response was not a valid property list." >&2
  [[ -s "$submission_stdout" ]] && cat "$submission_stdout" >&2
  [[ -s "$submission_stderr" ]] && cat "$submission_stderr" >&2
  exit 1
fi
rm -f "$submission_stdout" "$submission_stderr"

submission_id="$(/usr/bin/plutil -extract id raw -o - "$submission_plist" 2>/dev/null || true)"
submission_status="$(/usr/bin/plutil -extract status raw -o - "$submission_plist" 2>/dev/null || true)"
if [[ -z "$submission_id" && -n "$EXISTING_SUBMISSION_ID" ]]; then
  submission_id="$EXISTING_SUBMISSION_ID"
fi

if [[ -z "$submission_id" ]]; then
  echo "Apple's submission response did not include a submission ID." >&2
  echo "Response: $submission_plist" >&2
  exit 1
fi

if [[ "$submit_exit" -ne 0 && -z "$submission_status" ]]; then
  echo "Apple did not finish processing within $NOTARY_TIMEOUT." >&2
  echo "Resume without uploading again:" >&2
  echo "  GT_NOTARY_SUBMISSION_ID=$submission_id $0 $DMG_PATH" >&2
  echo "Response: $submission_plist" >&2
  exit 1
fi

echo "==> Downloading Apple notarization log"
rm -f "$notary_log"
if ! xcrun notarytool log "$submission_id" "$notary_log" \
  --keychain-profile "$NOTARY_PROFILE"; then
  echo "Could not retrieve Apple's notarization log for $submission_id." >&2
  exit 1
fi
if [[ ! -s "$notary_log" ]] ||
  ! /usr/bin/plutil -p "$notary_log" >/dev/null 2>&1; then
  echo "Apple's notarization log is missing or invalid: $notary_log" >&2
  exit 1
fi
log_status="$(/usr/bin/plutil -extract status raw -o - "$notary_log" 2>/dev/null || true)"
log_issue_count="$(/usr/bin/plutil -extract issues raw -o - "$notary_log" 2>/dev/null || true)"
log_sha256="$(/usr/bin/plutil -extract sha256 raw -o - "$notary_log" 2>/dev/null || true)"
log_sha256="$(printf '%s' "$log_sha256" | tr '[:upper:]' '[:lower:]')"
if [[ -z "$log_issue_count" ]] &&
  /usr/bin/plutil -p "$notary_log" 2>/dev/null | grep -Fq '"issues" => <null>'; then
  log_issue_count="0"
fi
if [[ "$log_sha256" != "$local_sha256" ]]; then
  echo "Apple's notarization log belongs to a different artifact." >&2
  echo "Review: $notary_log" >&2
  exit 1
fi
if [[ "$log_status" != "Accepted" || "$log_issue_count" != "0" ]]; then
  echo "Apple's notarization log reports status '${log_status:-missing}' with ${log_issue_count:-unknown} issue(s)." >&2
  echo "Review: $notary_log" >&2
  exit 1
fi

if [[ "$submit_exit" -ne 0 || "$submission_status" != "Accepted" ]]; then
  echo "Apple notarization was not accepted (status: ${submission_status:-missing})." >&2
  echo "Review: $notary_log" >&2
  exit 1
fi

echo "==> Stapling and validating ticket"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "==> Verifying DMG integrity and Gatekeeper acceptance"
hdiutil verify "$DMG_PATH" >/dev/null
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

echo "==> Verifying mounted app through Gatekeeper"
hdiutil attach "$DMG_PATH" -mountpoint "$mount_root" -nobrowse -readonly -quiet
attached=1
mounted_app="$mount_root/$APP_NAME"
if [[ ! -d "$mounted_app" ]]; then
  echo "The notarized DMG does not contain $APP_NAME at its root." >&2
  exit 1
fi
mounted_webrtc="$mounted_app/Contents/Frameworks/WebRTC.framework"
if [[ ! -d "$mounted_webrtc" ]]; then
  echo "The notarized app does not contain WebRTC.framework." >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$mounted_app"
require_developer_id_signature "$mounted_app" "Mounted app"
codesign --verify --strict --verbose=2 "$mounted_webrtc"
require_developer_id_signature "$mounted_webrtc" "Mounted WebRTC.framework"
spctl --assess --type execute --verbose=4 "$mounted_app"
hdiutil detach "$mount_root" -quiet
attached=0

echo "==> Notarized release accepted"
echo "    Submission: $submission_id"
echo "    Response:   $submission_plist"
echo "    Apple log:  $notary_log"
