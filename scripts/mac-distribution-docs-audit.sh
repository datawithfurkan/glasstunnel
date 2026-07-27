#!/usr/bin/env bash
# Guard the Mac distribution runbook against drifting from release scripts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$ROOT_DIR/docs/mac-distribution.md"
READINESS="$ROOT_DIR/docs/public-release-readiness.md"
BUILD_SCRIPT="$ROOT_DIR/scripts/build-app.sh"
PREFLIGHT_SCRIPT="$ROOT_DIR/scripts/mac-release-preflight.sh"
INSTALL_SMOKE_SCRIPT="$ROOT_DIR/scripts/mac-install-upgrade-smoke.sh"
CASK_UPDATE_SMOKE="$ROOT_DIR/scripts/homebrew-cask-update-smoke.sh"
CASK_AUDIT="$ROOT_DIR/scripts/homebrew-cask-audit.sh"
CASK_INSTALL_SMOKE="$ROOT_DIR/scripts/homebrew-cask-local-install-smoke.sh"
NOTARIZATION_SCRIPT="$ROOT_DIR/scripts/notarize-mac-release.sh"
NOTARIZATION_SMOKE="$ROOT_DIR/scripts/mac-notarization-smoke.sh"
ENTITLEMENTS="$ROOT_DIR/apps/host-macos/Metadata/entitlements.plist"
INFO_PLIST="$ROOT_DIR/apps/host-macos/Metadata/Info.plist"
DEV_SCRIPT="$ROOT_DIR/scripts/dev-app.sh"
FAILURES=0

fail() {
  echo "Mac distribution docs audit failed: $*" >&2
  FAILURES=$((FAILURES + 1))
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    fail "missing required file: ${path#$ROOT_DIR/}"
  fi
}

require_text() {
  local path="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" "$path"; then
    fail "${path#$ROOT_DIR/} must mention: $needle"
  fi
}

require_script_text() {
  local path="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" "$path"; then
    fail "${path#$ROOT_DIR/} is missing expected release-script surface: $needle"
  fi
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

echo "Glasstunnel Mac distribution docs audit"
echo "Repo: $ROOT_DIR"
echo "Commit: $(git rev-parse --short HEAD) $(git log -1 --pretty=%s)"
echo

for file in "$DOC" "$READINESS" "$BUILD_SCRIPT" "$PREFLIGHT_SCRIPT" "$INSTALL_SMOKE_SCRIPT" "$CASK_UPDATE_SMOKE" "$CASK_AUDIT" "$CASK_INSTALL_SMOKE" "$NOTARIZATION_SCRIPT" "$NOTARIZATION_SMOKE" "$ENTITLEMENTS" "$INFO_PLIST" "$DEV_SCRIPT"; do
  require_file "$file"
done

if [[ ! -f "$DOC" ]]; then
  exit 1
fi

release_bundle_id="$(plist_value "$INFO_PLIST" CFBundleIdentifier)"
dev_bundle_id="$(GLASSTUNNEL_DEV_BUNDLE_ID= bash "$DEV_SCRIPT" --print-bundle-id 2>/dev/null || true)"
notary_profile="glasstunnel-notary"

require_text "$DOC" "pnpm release:mac:preflight"
require_text "$DOC" "GT_DEVELOPER_ID"
require_text "$DOC" "GT_NOTARY_PROFILE"
require_text "$DOC" "$notary_profile"
require_text "$DOC" "--live-notary --require-release-creds"
require_text "$DOC" "./scripts/build-app.sh --ad-hoc"
require_text "$DOC" "./scripts/build-app.sh --local-sign"
require_text "$DOC" "scripts/ensure-dev-codesign-identity.sh"
require_text "$DOC" "dev-signing-keychain-password"
require_text "$DOC" "lives outside the repository"
require_text "$DOC" "GT_MAC_INSTALL_REQUIRE_UPGRADE=1"
require_text "$DOC" "designated signing requirement"
require_text "$DOC" "This mode is for local packaging checks only."
require_text "$DOC" "It does not prove Developer ID signing, notarization, Gatekeeper behavior, or production macOS TCC identity."
require_text "$DOC" "pnpm release:mac:install-smoke"
require_text "$DOC" "It does not launch the"
require_text "$DOC" "required signed"
require_text "$DOC" "embedded signed \`WebRTC.framework\`"
require_text "$DOC" "isolated SwiftPM scratch directories"
require_text "$DOC" "Gatekeeper first launch"
require_text "$DOC" "notarization."
require_text "$DOC" "./scripts/build-app.sh --skip-notarize"
require_text "$DOC" "notarytool submit"
require_text "$DOC" "Staples and validates the DMG ticket"
require_text "$DOC" "pnpm qa:mac:cask-audit"
require_text "$DOC" "pnpm qa:mac:cask-update"
require_text "$DOC" "pnpm qa:mac:cask-install"
require_text "$DOC" "pnpm qa:mac:notarization"
require_text "$DOC" "Apple's notarization log"
require_text "$DOC" "Gatekeeper to accept both the DMG and its mounted app"
require_text "$DOC" "GT_NOTARY_SUBMISSION_ID"
require_text "$DOC" "SHA-256 in Apple's log"
require_text "$DOC" "Do not assemble release bundles manually."
require_text "$DOC" "If you change entitlements, re-notarize."

if [[ -n "$release_bundle_id" ]]; then
  require_text "$DOC" "Release app: \`$release_bundle_id\`"
else
  fail "could not read release bundle identifier from apps/host-macos/Metadata/Info.plist"
fi

if [[ -n "$dev_bundle_id" ]]; then
  require_text "$DOC" "Development wrapper: \`$dev_bundle_id\`"
else
  fail "could not read development bundle identifier from scripts/dev-app.sh"
fi

for entitlement in \
  "com.apple.security.device.screen-capture" \
  "com.apple.security.automation.apple-events" \
  "com.apple.security.cs.disable-library-validation"; do
  require_text "$DOC" "$entitlement"
done

require_script_text "$BUILD_SCRIPT" "--ad-hoc"
require_script_text "$BUILD_SCRIPT" "--local-sign"
require_script_text "$BUILD_SCRIPT" "Preparing local development signing keychain"
require_script_text "$BUILD_SCRIPT" "ensure-dev-codesign-identity.sh"
require_script_text "$BUILD_SCRIPT" "--skip-notarize"
require_script_text "$BUILD_SCRIPT" "GTSourceCommit"
require_script_text "$BUILD_SCRIPT" "GTSourceDirty"
require_script_text "$BUILD_SCRIPT" "Contents/Frameworks/WebRTC.framework"
require_script_text "$BUILD_SCRIPT" "lipo -create"
require_script_text "$BUILD_SCRIPT" "notarize-mac-release.sh"
require_script_text "$BUILD_SCRIPT" "Developer ID releases must be built from a clean source tree."
require_script_text "$PREFLIGHT_SCRIPT" "--live-notary"
require_script_text "$PREFLIGHT_SCRIPT" "--require-release-creds"
require_script_text "$PREFLIGHT_SCRIPT" "does not prompt for keychain passwords intentionally"
require_script_text "$PREFLIGHT_SCRIPT" "Existing app runtime"
require_script_text "$INSTALL_SMOKE_SCRIPT" "does not prove Developer ID notarization"
require_script_text "$INSTALL_SMOKE_SCRIPT" "REQUIRED_RELEASE_ENTITLEMENTS"
require_script_text "$INSTALL_SMOKE_SCRIPT" "missing signed entitlement"
require_script_text "$INSTALL_SMOKE_SCRIPT" "GT_MAC_INSTALL_REQUIRE_UPGRADE"
require_script_text "$INSTALL_SMOKE_SCRIPT" "designated signing requirement changed"
require_script_text "$INSTALL_SMOKE_SCRIPT" "missing embedded WebRTC.framework"
require_script_text "$CASK_UPDATE_SMOKE" "GT_CASK_FILE"
require_script_text "$CASK_UPDATE_SMOKE" "sha256 :no_check"
require_script_text "$CASK_AUDIT" "brew audit --cask --strict"
require_script_text "$CASK_AUDIT" "brew tap-new --no-git"
require_script_text "$CASK_INSTALL_SMOKE" "brew tap-new --no-git"
require_script_text "$CASK_INSTALL_SMOKE" "HOMEBREW_NO_AUTO_UPDATE"
require_script_text "$NOTARIZATION_SCRIPT" "notarytool submit"
require_script_text "$NOTARIZATION_SCRIPT" "notarytool wait"
require_script_text "$NOTARIZATION_SCRIPT" "notarytool log"
require_script_text "$NOTARIZATION_SCRIPT" "stapler validate"
require_script_text "$NOTARIZATION_SCRIPT" "spctl --assess --type open"
require_script_text "$NOTARIZATION_SCRIPT" "spctl --assess --type execute"
require_script_text "$NOTARIZATION_SMOKE" "GT_SMOKE_NOTARY_STATUS"

require_text "$READINESS" "- [x] Developer ID signing path is documented and tested."
require_text "$READINESS" "- [x] Notarization path is documented and tested."
require_text "$READINESS" "Developer ID signing/notarization"

if [[ "$FAILURES" -gt 0 ]]; then
  exit 1
fi

echo "Mac distribution docs audit completed."
echo "This audit verifies runbook/script alignment only; it does not sign, notarize, staple, launch, or touch macOS TCC state."
