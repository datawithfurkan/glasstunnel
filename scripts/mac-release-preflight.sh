#!/usr/bin/env bash
# Check local Mac release prerequisites without building or exposing secrets.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_ID="${GT_DEVELOPER_ID:-}"
NOTARY_PROFILE="${GT_NOTARY_PROFILE:-glasstunnel-notary}"
LIVE_NOTARY=0
REQUIRE_RELEASE_CREDS=0
STATUS_ROWS=()
FAILURES=0
EXPECTED_RELEASE_BUNDLE_ID="io.glasstunnel.host"
EXPECTED_DEV_BUNDLE_ID="io.glasstunnel.host.dev"
RELEASE_ENTITLEMENTS="$ROOT_DIR/apps/host-macos/Metadata/entitlements.plist"
REQUIRED_RELEASE_ENTITLEMENTS=(
  "com.apple.security.cs.disable-library-validation"
  "com.apple.security.automation.apple-events"
  "com.apple.security.device.screen-capture"
)
REQUIRED_ARCHS=(arm64 x86_64)
TEMP_FILES=()

cleanup() {
  if [[ "${#TEMP_FILES[@]}" -gt 0 ]]; then
    rm -f "${TEMP_FILES[@]}"
  fi
}

trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage: bash scripts/mac-release-preflight.sh [--live-notary] [--require-release-creds]

Checks local prerequisites for distributing the Glasstunnel Mac app.

Default mode is safe for normal development:
  - verifies required local tools
  - checks whether GT_DEVELOPER_ID is set and installed
  - checks existing dist/ artifacts when present
  - does not contact Apple notary services
  - does not prompt for keychain passwords intentionally

Options:
  --live-notary           Verify the notarytool keychain profile by calling Apple.
  --require-release-creds Fail when Developer ID or live notary credentials are missing.

Environment:
  GT_DEVELOPER_ID         Developer ID Application identity for release signing.
  GT_NOTARY_PROFILE       notarytool keychain profile name. Defaults to glasstunnel-notary.
USAGE
}

add_row() {
  STATUS_ROWS+=("$1|$2|$3")
}

fail_row() {
  add_row "$1" "fail" "$2"
  FAILURES=$((FAILURES + 1))
}

warn_row() {
  add_row "$1" "warn" "$2"
}

pass_row() {
  add_row "$1" "pass" "$2"
}

is_release_only_artifact_path() {
  case "$1" in
    Casks/glasstunnel.rb|\
    docs/*|\
    scripts/check-agent-app-release-claims.sh|\
    scripts/lab/workflow-contract.test.mjs|\
    scripts/mac-install-upgrade-smoke.sh|\
    scripts/mac-release-preflight.sh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

plist_bool_enabled() {
  local plist="$1"
  local key="$2"
  local value
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
  [[ "$value" == "true" ]]
}

signed_artifact_entitlements() {
  local app_dir="$1"
  local output
  output="$(mktemp "${TMPDIR:-/tmp}/glasstunnel-signed-entitlements.XXXXXX")"
  TEMP_FILES+=("$output")
  if codesign -d --entitlements :- "$app_dir" >"$output" 2>/dev/null; then
    printf '%s\n' "$output"
    return 0
  fi
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --)
      ;;
    --live-notary)
      LIVE_NOTARY=1
      ;;
    --require-release-creds)
      REQUIRE_RELEASE_CREDS=1
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

cd "$ROOT_DIR"
CURRENT_COMMIT="$(git rev-parse HEAD)"

for tool in swift xcrun codesign security hdiutil; do
  if command -v "$tool" >/dev/null 2>&1; then
    pass_row "$tool" "$(command -v "$tool")"
  else
    fail_row "$tool" "Required for Mac release packaging."
  fi
done

if command -v brew >/dev/null 2>&1; then
  pass_row "Homebrew" "$(brew --version | head -n 1)"
else
  warn_row "Homebrew" "Not installed; cask audit cannot run locally."
fi

if [[ -z "$DEVELOPER_ID" ]]; then
  if [[ "$REQUIRE_RELEASE_CREDS" == "1" ]]; then
    fail_row "Developer ID" "GT_DEVELOPER_ID is not set."
  else
    warn_row "Developer ID" "GT_DEVELOPER_ID is not set; Developer ID signing is unverified."
  fi
elif [[ "$DEVELOPER_ID" != "Developer ID Application: "* ]]; then
  if [[ "$REQUIRE_RELEASE_CREDS" == "1" ]]; then
    fail_row "Developer ID" "GT_DEVELOPER_ID must name a Developer ID Application identity."
  else
    warn_row "Developer ID" "GT_DEVELOPER_ID does not name a Developer ID Application identity."
  fi
else
  if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$DEVELOPER_ID\""; then
    pass_row "Developer ID" "Identity is installed in the local keychain."
  else
    if [[ "$REQUIRE_RELEASE_CREDS" == "1" ]]; then
      fail_row "Developer ID" "GT_DEVELOPER_ID is set but not found by security find-identity."
    else
      warn_row "Developer ID" "GT_DEVELOPER_ID is set but not found by security find-identity."
    fi
  fi
fi

if [[ "$LIVE_NOTARY" == "1" ]]; then
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null 2>&1; then
    pass_row "Notary profile" "Profile '$NOTARY_PROFILE' authenticated successfully."
  else
    if [[ "$REQUIRE_RELEASE_CREDS" == "1" ]]; then
      fail_row "Notary profile" "Profile '$NOTARY_PROFILE' could not authenticate with notarytool."
    else
      warn_row "Notary profile" "Profile '$NOTARY_PROFILE' could not authenticate with notarytool."
    fi
  fi
else
  if [[ "$REQUIRE_RELEASE_CREDS" == "1" ]]; then
    fail_row "Notary profile" "Run with --live-notary to verify '$NOTARY_PROFILE'."
  else
    warn_row "Notary profile" "Skipped live check; run with --live-notary before release."
  fi
fi

INFO_PLIST="$ROOT_DIR/apps/host-macos/Metadata/Info.plist"
if [[ -f "$INFO_PLIST" ]]; then
  release_bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST" 2>/dev/null || true)"
  if [[ "$release_bundle_id" == "$EXPECTED_RELEASE_BUNDLE_ID" ]]; then
    pass_row "Release bundle ID" "$release_bundle_id"
  else
    fail_row "Release bundle ID" "Expected $EXPECTED_RELEASE_BUNDLE_ID, found '${release_bundle_id:-missing}'."
  fi
else
  fail_row "Release bundle ID" "Missing apps/host-macos/Metadata/Info.plist."
fi

if [[ -f "$RELEASE_ENTITLEMENTS" ]]; then
  missing_entitlements=()
  for entitlement in "${REQUIRED_RELEASE_ENTITLEMENTS[@]}"; do
    if ! plist_bool_enabled "$RELEASE_ENTITLEMENTS" "$entitlement"; then
      missing_entitlements+=("$entitlement")
    fi
  done
  if [[ "${#missing_entitlements[@]}" -eq 0 ]]; then
    pass_row "Release entitlements" "Required release entitlements are enabled."
  else
    fail_row "Release entitlements" "Missing or false: ${missing_entitlements[*]}"
  fi
else
  fail_row "Release entitlements" "Missing apps/host-macos/Metadata/entitlements.plist."
fi

DEV_APP_SCRIPT="$ROOT_DIR/scripts/dev-app.sh"
if [[ -f "$DEV_APP_SCRIPT" ]]; then
  dev_bundle_id="$(GLASSTUNNEL_DEV_BUNDLE_ID= bash "$DEV_APP_SCRIPT" --print-bundle-id 2>/dev/null || true)"
  if [[ "$dev_bundle_id" == "$EXPECTED_DEV_BUNDLE_ID" ]]; then
    pass_row "Development bundle ID" "$dev_bundle_id"
  else
    fail_row "Development bundle ID" "Expected $EXPECTED_DEV_BUNDLE_ID, found '${dev_bundle_id:-missing}'."
  fi
else
  fail_row "Development bundle ID" "Missing scripts/dev-app.sh."
fi

APP_DIR="$ROOT_DIR/dist/Glasstunnel.app"
if [[ -d "$APP_DIR" ]]; then
  APP_BINARY="$APP_DIR/Contents/MacOS/GlassTunnel"
  WEBRTC_FRAMEWORK="$APP_DIR/Contents/Frameworks/WebRTC.framework"
  WEBRTC_BINARY="$WEBRTC_FRAMEWORK/WebRTC"
  artifact_bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$artifact_bundle_id" == "$EXPECTED_RELEASE_BUNDLE_ID" ]]; then
    pass_row "Existing app bundle ID" "$artifact_bundle_id"
  else
    fail_row "Existing app bundle ID" "Expected $EXPECTED_RELEASE_BUNDLE_ID, found '${artifact_bundle_id:-missing}'."
  fi
  if codesign --verify --deep --strict "$APP_DIR" >/dev/null 2>&1; then
    pass_row "Existing app artifact" "dist/Glasstunnel.app verifies with codesign."
  else
    fail_row "Existing app artifact" "dist/Glasstunnel.app failed codesign verification."
  fi
  if [[ -x "$APP_BINARY" && -f "$WEBRTC_BINARY" ]]; then
    missing_archs=()
    for arch in "${REQUIRED_ARCHS[@]}"; do
      if [[ " $(/usr/bin/lipo -archs "$APP_BINARY") " != *" $arch "* ]]; then
        missing_archs+=("app:$arch")
      fi
      if [[ " $(/usr/bin/lipo -archs "$WEBRTC_BINARY") " != *" $arch "* ]]; then
        missing_archs+=("WebRTC:$arch")
      fi
    done
    if [[ "${#missing_archs[@]}" -eq 0 ]] && \
      otool -L "$APP_BINARY" | grep -F '@rpath/WebRTC.framework/WebRTC' >/dev/null && \
      otool -l "$APP_BINARY" | grep -F 'path @executable_path/../Frameworks' >/dev/null && \
      codesign --verify --strict "$WEBRTC_FRAMEWORK" >/dev/null 2>&1; then
      pass_row "Existing app runtime" "Universal executable and embedded WebRTC.framework verify."
    else
      fail_row "Existing app runtime" "Missing architecture/runtime-link/signature requirement: ${missing_archs[*]:-WebRTC framework or rpath}."
    fi
  else
    fail_row "Existing app runtime" "Missing universal executable or embedded Contents/Frameworks/WebRTC.framework."
  fi
  artifact_source_commit="$(/usr/libexec/PlistBuddy -c "Print :GTSourceCommit" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)"
  artifact_source_dirty="$(/usr/libexec/PlistBuddy -c "Print :GTSourceDirty" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$artifact_source_dirty" != "false" ]]; then
    fail_row "Existing app source" "Artifact source was built from a dirty tree."
  elif [[ "$artifact_source_commit" == "$CURRENT_COMMIT" ]]; then
    pass_row "Existing app source" "Artifact is bound to current clean commit ${CURRENT_COMMIT:0:8}."
  elif git rev-parse --verify "${artifact_source_commit}^{commit}" >/dev/null 2>&1 && \
    git merge-base --is-ancestor "$artifact_source_commit" "$CURRENT_COMMIT"; then
    non_release_paths=()
    while IFS= read -r changed_path; do
      [[ -z "$changed_path" ]] && continue
      if ! is_release_only_artifact_path "$changed_path"; then
        non_release_paths+=("$changed_path")
      fi
    done < <(git diff --name-only "$artifact_source_commit" --)

    if [[ "${#non_release_paths[@]}" -eq 0 ]]; then
      pass_row "Existing app source" "Artifact is bound to ${artifact_source_commit:0:8}; descendants contain release-only metadata."
    else
      fail_row "Existing app source" "Rebuild required; non-release paths changed after ${artifact_source_commit:0:8}: ${non_release_paths[*]}."
    fi
  else
    fail_row "Existing app source" "Rebuild required; artifact commit '${artifact_source_commit:-missing}' is not an ancestor of current HEAD."
  fi
  if artifact_entitlements="$(signed_artifact_entitlements "$APP_DIR")"; then
    missing_artifact_entitlements=()
    for entitlement in "${REQUIRED_RELEASE_ENTITLEMENTS[@]}"; do
      if ! plist_bool_enabled "$artifact_entitlements" "$entitlement"; then
        missing_artifact_entitlements+=("$entitlement")
      fi
    done
    if [[ "${#missing_artifact_entitlements[@]}" -eq 0 ]]; then
      pass_row "Existing app entitlements" "dist/Glasstunnel.app carries required release entitlements."
    else
      fail_row "Existing app entitlements" "Missing or false in signed app: ${missing_artifact_entitlements[*]}"
    fi
  else
    fail_row "Existing app entitlements" "Could not read signed entitlements from dist/Glasstunnel.app."
  fi
else
  warn_row "Existing app artifact" "Not present; run scripts/build-app.sh --local-sign VERSION for repeatable local packaging."
fi

shopt -s nullglob
DMGS=("$ROOT_DIR"/dist/Glasstunnel-*.dmg)
shopt -u nullglob

if [[ "${#DMGS[@]}" -eq 0 ]]; then
  warn_row "Existing DMG artifact" "Not present; run scripts/build-app.sh --local-sign VERSION for repeatable local packaging."
else
  latest_dmg="${DMGS[0]}"
  for dmg in "${DMGS[@]}"; do
    if [[ "$dmg" -nt "$latest_dmg" ]]; then
      latest_dmg="$dmg"
    fi
  done
  if hdiutil verify "$latest_dmg" >/dev/null 2>&1; then
    pass_row "Existing DMG artifact" "$(basename "$latest_dmg") verifies with hdiutil."
  else
    fail_row "Existing DMG artifact" "$(basename "$latest_dmg") failed hdiutil verification."
  fi
fi

echo "Glasstunnel Mac release preflight"
echo "Repo: $ROOT_DIR"
echo "Commit: $(git rev-parse --short HEAD) $(git log -1 --pretty=%s)"
echo
printf '%-24s %-6s %s\n' "Check" "Status" "Detail"
printf '%-24s %-6s %s\n' "-----" "------" "------"
for row in "${STATUS_ROWS[@]}"; do
  IFS='|' read -r name status detail <<<"$row"
  printf '%-24s %-6s %s\n' "$name" "$status" "$detail"
done
echo

if [[ "$FAILURES" -gt 0 ]]; then
  echo "Mac release preflight failed with $FAILURES blocking issue(s)." >&2
  exit 1
fi

echo "Mac release preflight completed."
if [[ -z "$DEVELOPER_ID" || "$LIVE_NOTARY" != "1" ]]; then
  echo "Release signing/notarization remains unverified until Developer ID and live notary checks pass."
fi
