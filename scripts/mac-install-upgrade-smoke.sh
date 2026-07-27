#!/usr/bin/env bash
# Verify packaged Mac app reinstall and optional version-to-version upgrade.
#
# This smoke uses an isolated temp install root. It does not copy into
# /Applications, launch Glasstunnel, reset TCC permissions, or contact Apple.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="Glasstunnel.app"
EXPECTED_BUNDLE_ID="io.glasstunnel.host"
REQUIRED_ARCHS=(arm64 x86_64)
INITIAL_DMG="${GT_MAC_INSTALL_DMG:-}"
UPGRADE_DMG="${GT_MAC_INSTALL_UPGRADE_DMG:-}"
REQUIRE_UPGRADE="${GT_MAC_INSTALL_REQUIRE_UPGRADE:-0}"
KEEP_TMP="${GT_MAC_INSTALL_SMOKE_KEEP_TMP:-0}"
REQUIRED_RELEASE_ENTITLEMENTS=(
  "com.apple.security.cs.disable-library-validation"
  "com.apple.security.automation.apple-events"
  "com.apple.security.device.screen-capture"
)

usage() {
  cat <<'USAGE'
Usage: bash scripts/mac-install-upgrade-smoke.sh [initial.dmg] [upgrade.dmg]

Verifies a packaged Glasstunnel DMG by mounting it, copying Glasstunnel.app into
an isolated temporary Applications folder, reinstalling the same version, and
checking the resulting app bundle. Pass a second, newer DMG to prove an actual
version-to-version upgrade with the same bundle and signing identity.

Environment:
  GT_MAC_INSTALL_DMG               Initial DMG path when no first argument is supplied.
  GT_MAC_INSTALL_UPGRADE_DMG       Upgrade DMG path when no second argument is supplied.
  GT_MAC_INSTALL_REQUIRE_UPGRADE=1 Fail unless an upgrade DMG is supplied and tested.
  GT_MAC_INSTALL_SMOKE_KEEP_TMP=1  Keep the temp install root for inspection.
USAGE
}

if [[ "${1:-}" == "--" ]]; then
  shift
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 2 ]]; then
  echo "Too many arguments." >&2
  usage >&2
  exit 2
fi

if [[ $# -ge 1 ]]; then
  INITIAL_DMG="$1"
fi

if [[ $# -eq 2 ]]; then
  UPGRADE_DMG="$2"
fi

if [[ -z "$INITIAL_DMG" ]]; then
  shopt -s nullglob
  dmgs=("$DIST_DIR"/Glasstunnel-*.dmg)
  shopt -u nullglob
  if [[ "${#dmgs[@]}" -eq 0 ]]; then
    echo "No Glasstunnel DMG found in dist/." >&2
    echo "Build one first with: ./scripts/build-app.sh --ad-hoc 0.1.0" >&2
    exit 1
  fi
  INITIAL_DMG="${dmgs[0]}"
  for dmg in "${dmgs[@]}"; do
    if [[ "$dmg" -nt "$INITIAL_DMG" ]]; then
      INITIAL_DMG="$dmg"
    fi
  done
fi

if [[ ! -f "$INITIAL_DMG" ]]; then
  echo "Initial DMG not found: $INITIAL_DMG" >&2
  exit 1
fi

if [[ -n "$UPGRADE_DMG" && ! -f "$UPGRADE_DMG" ]]; then
  echo "Upgrade DMG not found: $UPGRADE_DMG" >&2
  exit 1
fi

if [[ "$REQUIRE_UPGRADE" == "1" && -z "$UPGRADE_DMG" ]]; then
  echo "GT_MAC_INSTALL_REQUIRE_UPGRADE=1 requires a second, newer DMG." >&2
  exit 1
fi

tmp_root="$(mktemp -d /tmp/glasstunnel-install-smoke.XXXXXX)"
mount_root="$tmp_root/mount"
install_root="$tmp_root/Applications"
mkdir -p "$mount_root" "$install_root"
current_commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"

attached=0
cleanup() {
  if [[ "$attached" == "1" ]]; then
    hdiutil detach "$mount_root" -quiet >/dev/null 2>&1 || true
  fi
  if [[ "$KEEP_TMP" != "1" ]]; then
    rm -rf "$tmp_root"
  else
    echo "Temp install root kept at: $tmp_root"
  fi
}
trap cleanup EXIT

detach_dmg() {
  if [[ "$attached" == "1" ]]; then
    hdiutil detach "$mount_root" -quiet
    attached=0
  fi
}

attach_dmg() {
  local dmg_path="$1"
  hdiutil attach "$dmg_path" -mountpoint "$mount_root" -nobrowse -readonly -quiet
  attached=1
}

VERIFIED_VERSION=""
VERIFIED_REQUIREMENT=""

verify_app() {
  local app_path="$1"
  local context="$2"
  local plist="$app_path/Contents/Info.plist"
  local binary="$app_path/Contents/MacOS/GlassTunnel"
  local webrtc_framework="$app_path/Contents/Frameworks/WebRTC.framework"
  local webrtc_binary="$webrtc_framework/WebRTC"

  [[ -d "$app_path" ]] || { echo "$context: missing app bundle at $app_path" >&2; exit 1; }
  [[ -f "$plist" ]] || { echo "$context: missing Info.plist" >&2; exit 1; }
  [[ -x "$binary" ]] || { echo "$context: missing executable" >&2; exit 1; }
  [[ -d "$webrtc_framework" ]] || { echo "$context: missing embedded WebRTC.framework" >&2; exit 1; }
  [[ -f "$webrtc_binary" ]] || { echo "$context: missing embedded WebRTC binary" >&2; exit 1; }

  local required_arch
  for required_arch in "${REQUIRED_ARCHS[@]}"; do
    if [[ " $(/usr/bin/lipo -archs "$binary") " != *" $required_arch "* ]]; then
      echo "$context: executable is missing required architecture $required_arch." >&2
      exit 1
    fi
    if [[ " $(/usr/bin/lipo -archs "$webrtc_binary") " != *" $required_arch "* ]]; then
      echo "$context: WebRTC.framework is missing required architecture $required_arch." >&2
      exit 1
    fi
  done

  if ! otool -L "$binary" | grep -F '@rpath/WebRTC.framework/WebRTC' >/dev/null; then
    echo "$context: executable does not link WebRTC.framework through @rpath." >&2
    exit 1
  fi
  if ! otool -l "$binary" | grep -F 'path @executable_path/../Frameworks' >/dev/null; then
    echo "$context: executable is missing the app Frameworks runtime search path." >&2
    exit 1
  fi

  local bundle_id
  bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null || true)"
  if [[ "$bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
    echo "$context: expected bundle ID $EXPECTED_BUNDLE_ID, found '${bundle_id:-missing}'." >&2
    exit 1
  fi

  local version
  version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null || true)"
  if [[ -z "$version" ]]; then
    echo "$context: missing CFBundleShortVersionString." >&2
    exit 1
  fi

  local source_commit source_dirty
  source_commit="$(/usr/libexec/PlistBuddy -c "Print :GTSourceCommit" "$plist" 2>/dev/null || true)"
  source_dirty="$(/usr/libexec/PlistBuddy -c "Print :GTSourceDirty" "$plist" 2>/dev/null || true)"
  if [[ "$source_commit" != "$current_commit" ]]; then
    echo "$context: artifact source commit '${source_commit:-missing}' does not match current HEAD $current_commit." >&2
    exit 1
  fi
  if [[ "$source_dirty" != "false" ]]; then
    echo "$context: artifact was built from a dirty or unbound source tree." >&2
    exit 1
  fi

  codesign --verify --deep --strict "$app_path" >/dev/null
  codesign --verify --strict "$webrtc_framework" >/dev/null

  local requirement
  requirement="$(codesign -d -r- "$app_path" 2>&1 | sed -n 's/^designated => //p')"
  if [[ -z "$requirement" ]]; then
    echo "$context: could not read the designated code-signing requirement." >&2
    exit 1
  fi

  local entitlements
  entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null || true)"
  if [[ -z "$entitlements" ]]; then
    echo "$context: could not read signed entitlements." >&2
    exit 1
  fi

  local entitlement
  for entitlement in "${REQUIRED_RELEASE_ENTITLEMENTS[@]}"; do
    if ! /usr/bin/grep -Fq "<key>$entitlement</key>" <<<"$entitlements"; then
      echo "$context: missing signed entitlement $entitlement." >&2
      exit 1
    fi
  done

  VERIFIED_VERSION="$version"
  VERIFIED_REQUIREMENT="$requirement"
}

echo "Glasstunnel Mac install/upgrade smoke"
echo "Repo: $ROOT_DIR"
echo "Commit: $(git rev-parse --short HEAD 2>/dev/null || printf unknown)"
echo "Initial DMG: $INITIAL_DMG"
if [[ -n "$UPGRADE_DMG" ]]; then
  echo "Upgrade DMG: $UPGRADE_DMG"
fi
echo

echo "==> Verifying initial DMG"
hdiutil verify "$INITIAL_DMG" >/dev/null

echo "==> Mounting initial DMG"
attach_dmg "$INITIAL_DMG"

source_app="$mount_root/$APP_NAME"
verify_app "$source_app" "mounted initial app"
initial_version="$VERIFIED_VERSION"
initial_requirement="$VERIFIED_REQUIREMENT"

installed_app="$install_root/$APP_NAME"

echo "==> Installing into isolated temp Applications"
ditto "$source_app" "$installed_app"
verify_app "$installed_app" "first install"

echo "==> Replacing installed copy"
rm -rf "$installed_app"
ditto "$source_app" "$installed_app"
verify_app "$installed_app" "same-version reinstall"

detach_dmg

upgrade_tested=0
if [[ -n "$UPGRADE_DMG" ]]; then
  echo "==> Verifying upgrade DMG"
  hdiutil verify "$UPGRADE_DMG" >/dev/null
  echo "==> Mounting upgrade DMG"
  attach_dmg "$UPGRADE_DMG"
  source_app="$mount_root/$APP_NAME"
  verify_app "$source_app" "mounted upgrade app"
  upgrade_version="$VERIFIED_VERSION"
  upgrade_requirement="$VERIFIED_REQUIREMENT"

  if [[ "$initial_version" == "$upgrade_version" || "$(printf '%s\n%s\n' "$initial_version" "$upgrade_version" | sort -V | tail -n 1)" != "$upgrade_version" ]]; then
    echo "upgrade app: expected a version newer than $initial_version, found $upgrade_version." >&2
    exit 1
  fi
  if [[ "$upgrade_requirement" != "$initial_requirement" ]]; then
    echo "upgrade app: designated signing requirement changed between versions." >&2
    exit 1
  fi

  echo "==> Upgrading installed copy from $initial_version to $upgrade_version"
  rm -rf "$installed_app"
  ditto "$source_app" "$installed_app"
  verify_app "$installed_app" "upgraded install"
  upgrade_tested=1
fi

echo
if [[ "$upgrade_tested" == "1" ]]; then
  echo "Result: passed; DMG app installs, reinstalls, and upgrades from $initial_version to $upgrade_version with current-source metadata, stable signing requirements, universal executable/frameworks, and required entitlements."
else
  echo "Result: passed; DMG app installs and reinstalls cleanly with current-source metadata, universal executable/frameworks, and required signed entitlements."
  echo "Upgrade was not exercised; pass a second, newer DMG or set GT_MAC_INSTALL_REQUIRE_UPGRADE=1 to require it."
fi
echo "This does not prove Developer ID notarization, Gatekeeper first launch, /Applications permissions, or macOS TCC attachment."
