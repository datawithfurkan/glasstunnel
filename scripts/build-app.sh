#!/usr/bin/env bash
# Build and optionally notarize the Glasstunnel Mac app.
#
# Developer ID release env vars:
#   GT_DEVELOPER_ID   "Developer ID Application: YOUR NAME (TEAMID)"
#   GT_NOTARY_PROFILE notarytool keychain profile name (default: glasstunnel-notary)
#
# In-app updates (Sparkle): Developer ID builds embed the public EdDSA key from
# apps/host-macos/Metadata/sparkle-public-ed-key.txt so the app can verify
# updates. Other builds get no key and send people to GitHub Releases instead.
#
# Usage: ./scripts/build-app.sh [--ad-hoc|--local-sign] [--skip-notarize] [version]
set -euo pipefail

VERSION="0.1.0"
SIGNING_MODE="developer-id"
NOTARIZE="1"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="$REPO/apps/host-macos"
DIST="$REPO/dist"
APP_NAME="Glasstunnel.app"
DEVELOPER_ID="${GT_DEVELOPER_ID:-}"
LOCAL_SIGN_IDENTITY="${GT_LOCAL_SIGN_IDENTITY:-Glasstunnel Local Development}"
NOTARY_PROFILE="${GT_NOTARY_PROFILE:-glasstunnel-notary}"
ENTITLEMENTS="$HOST/Metadata/entitlements.plist"
SPARKLE_PUBLIC_KEY_FILE="$HOST/Metadata/sparkle-public-ed-key.txt"
SPARKLE_PUBLIC_ED_KEY="${GT_SPARKLE_PUBLIC_ED_KEY:-}"
SPARKLE_FEED_URL="${GT_SPARKLE_FEED_URL:-}"
RELEASE_SCRATCH="$HOST/.build/glasstunnel-release"
REQUIRED_ARCHS=(arm64 x86_64)

usage() {
  cat <<'USAGE'
Usage: ./scripts/build-app.sh [--ad-hoc|--local-sign] [--skip-notarize] [version]

Builds dist/Glasstunnel.app and dist/Glasstunnel-VERSION.dmg.

Modes:
  default          Developer ID sign the app and DMG, then notarize and verify the release.
  --ad-hoc         Ad-hoc sign the app for local packaging verification. Skips DMG signing and notarization.
  --local-sign     Sign with a stable local identity for repeatable local TCC, reinstall, and upgrade tests.
  --skip-notarize Developer ID sign the app and DMG, but skip notarytool submission/stapling.

Environment:
  GT_DEVELOPER_ID       Developer ID Application identity for release signing.
  GT_LOCAL_SIGN_IDENTITY Stable local signing identity. Defaults to Glasstunnel Local Development.
                         Local mode prepares and unlocks its private keychain automatically.
  GT_NOTARY_PROFILE     notarytool keychain profile name. Defaults to glasstunnel-notary.
  GT_SPARKLE_PUBLIC_ED_KEY  Update-signing public key for this build. Developer ID builds
                         default to apps/host-macos/Metadata/sparkle-public-ed-key.txt;
                         other modes only get one when this is set (update smoke tests).
  GT_SPARKLE_FEED_URL   Replaces the update feed URL (update smoke tests only).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ad-hoc)
      SIGNING_MODE="ad-hoc"
      NOTARIZE="0"
      ;;
    --local-sign)
      SIGNING_MODE="local"
      NOTARIZE="0"
      ;;
    --skip-notarize)
      NOTARIZE="0"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      VERSION="$1"
      ;;
  esac
  shift
done

DMG_NAME="Glasstunnel-$VERSION.dmg"

if [[ "$SIGNING_MODE" == "developer-id" && -z "$DEVELOPER_ID" ]]; then
  echo "GT_DEVELOPER_ID must be set to your 'Developer ID Application: ...' cert identity" >&2
  echo "Find it with: security find-identity -v -p codesigning" >&2
  echo "For local packaging verification without Developer ID, run: ./scripts/build-app.sh --ad-hoc $VERSION" >&2
  exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
  echo "Invalid release version: $VERSION" >&2
  exit 2
fi

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  if [[ "$DEVELOPER_ID" != "Developer ID Application: "* ]]; then
    echo "GT_DEVELOPER_ID must name a Developer ID Application identity." >&2
    exit 1
  fi
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$DEVELOPER_ID\""; then
    echo "Developer ID identity '$DEVELOPER_ID' was not found in the local keychain." >&2
    exit 1
  fi
fi

if [[ "$SIGNING_MODE" == "developer-id" && -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  if [[ -f "$SPARKLE_PUBLIC_KEY_FILE" ]]; then
    SPARKLE_PUBLIC_ED_KEY="$(tr -d '[:space:]' <"$SPARKLE_PUBLIC_KEY_FILE")"
  fi
  if [[ -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    echo "Release builds need the in-app update public key in $SPARKLE_PUBLIC_KEY_FILE." >&2
    echo "Create the key pair once with Sparkle's generate_keys (see docs/mac-distribution.md)." >&2
    exit 1
  fi
fi
if [[ -n "$SPARKLE_PUBLIC_ED_KEY" && ! "$SPARKLE_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  echo "The update public key must be a base64 Ed25519 key (44 characters)." >&2
  exit 1
fi

if [[ "$SIGNING_MODE" == "local" ]]; then
  LOCAL_SIGN_HELPER="$REPO/scripts/ensure-dev-codesign-identity.sh"
  if [[ ! -x "$LOCAL_SIGN_HELPER" ]]; then
    echo "Local signing helper is missing or not executable: $LOCAL_SIGN_HELPER" >&2
    exit 1
  fi

  echo "==> Preparing local development signing keychain"
  if ! RESOLVED_LOCAL_SIGN_IDENTITY="$(
    GLASSTUNNEL_DEV_CODESIGN_IDENTITY="$LOCAL_SIGN_IDENTITY" \
      "$LOCAL_SIGN_HELPER"
  )"; then
    echo "Could not prepare the local development signing keychain." >&2
    exit 1
  fi
  if [[ "$RESOLVED_LOCAL_SIGN_IDENTITY" != "$LOCAL_SIGN_IDENTITY" ]]; then
    echo "Local signing helper returned an unexpected identity: $RESOLVED_LOCAL_SIGN_IDENTITY" >&2
    exit 1
  fi
fi

SOURCE_COMMIT="$(git -C "$REPO" rev-parse HEAD)"
SOURCE_DIRTY="false"
if [[ -n "$(git -C "$REPO" status --porcelain)" ]]; then
  SOURCE_DIRTY="true"
fi
if [[ "$SIGNING_MODE" == "developer-id" && "$SOURCE_DIRTY" == "true" ]]; then
  echo "Developer ID releases must be built from a clean source tree." >&2
  echo "Commit, ignore, or remove local changes before building the release." >&2
  exit 1
fi

echo "==> Building universal release"
cd "$HOST"
BUILD_DIRS=()
for arch in "${REQUIRED_ARCHS[@]}"; do
  scratch="$RELEASE_SCRATCH/$arch"
  echo "==> Building $arch"
  swift build -c release --arch "$arch" --scratch-path "$scratch"
  build_dir="$(swift build -c release --arch "$arch" --scratch-path "$scratch" --show-bin-path)"
  [[ -x "$build_dir/GlassTunnel" ]] || { echo "$arch release binary not found at $build_dir/GlassTunnel" >&2; exit 1; }
  [[ -d "$build_dir/WebRTC.framework" ]] || { echo "$arch WebRTC.framework not found at $build_dir" >&2; exit 1; }
  [[ -d "$build_dir/Sparkle.framework" ]] || { echo "$arch Sparkle.framework not found at $build_dir" >&2; exit 1; }
  BUILD_DIRS+=("$build_dir")
done

ARM_BUILD_DIR="${BUILD_DIRS[0]}"
X86_BUILD_DIR="${BUILD_DIRS[1]}"
WEBRTC_SOURCE="$ARM_BUILD_DIR/WebRTC.framework"
SPARKLE_SOURCE="$ARM_BUILD_DIR/Sparkle.framework"
for arch in "${REQUIRED_ARCHS[@]}"; do
  if [[ " $(/usr/bin/lipo -archs "$WEBRTC_SOURCE/WebRTC") " != *" $arch "* ]]; then
    echo "WebRTC.framework is missing required architecture $arch." >&2
    exit 1
  fi
  if [[ " $(/usr/bin/lipo -archs "$SPARKLE_SOURCE/Versions/B/Sparkle") " != *" $arch "* ]]; then
    echo "Sparkle.framework is missing required architecture $arch." >&2
    exit 1
  fi
done

echo "==> Assembling $APP_NAME"
rm -rf "$DIST/$APP_NAME"
mkdir -p "$DIST/$APP_NAME/Contents/MacOS"
mkdir -p "$DIST/$APP_NAME/Contents/Resources"
mkdir -p "$DIST/$APP_NAME/Contents/Frameworks"
/usr/bin/lipo -create \
  "$ARM_BUILD_DIR/GlassTunnel" \
  "$X86_BUILD_DIR/GlassTunnel" \
  -output "$DIST/$APP_NAME/Contents/MacOS/GlassTunnel"
cp -R "$WEBRTC_SOURCE" "$DIST/$APP_NAME/Contents/Frameworks/"
# ditto keeps the framework's symlinks, which its signature depends on. The
# app is not sandboxed, so Sparkle's XPC services are never used: drop them.
SPARKLE_DEST="$DIST/$APP_NAME/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE_SOURCE" "$SPARKLE_DEST"
rm -rf "$SPARKLE_DEST/Versions/B/XPCServices" "$SPARKLE_DEST/XPCServices"

# Package any dynamically linked SwiftPM libraries as universal binaries.
shopt -s nullglob
for arm_dylib in "$ARM_BUILD_DIR"/*.dylib; do
  dylib_name="$(basename "$arm_dylib")"
  x86_dylib="$X86_BUILD_DIR/$dylib_name"
  [[ -f "$x86_dylib" ]] || { echo "Missing x86_64 counterpart for $dylib_name" >&2; exit 1; }
  /usr/bin/lipo -create "$arm_dylib" "$x86_dylib" \
    -output "$DIST/$APP_NAME/Contents/Frameworks/$dylib_name"
done
for x86_dylib in "$X86_BUILD_DIR"/*.dylib; do
  dylib_name="$(basename "$x86_dylib")"
  [[ -f "$ARM_BUILD_DIR/$dylib_name" ]] || { echo "Missing arm64 counterpart for $dylib_name" >&2; exit 1; }
done
shopt -u nullglob

cp "$HOST/Metadata/Info.plist" "$DIST/$APP_NAME/Contents/Info.plist"
cp "$HOST/Metadata/AppIcon.icns" "$DIST/$APP_NAME/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$DIST/$APP_NAME/Contents/Info.plist" || true
# Sparkle compares CFBundleVersion, so it must grow with every release.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$DIST/$APP_NAME/Contents/Info.plist"
if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$DIST/$APP_NAME/Contents/Info.plist"
fi
if [[ -n "$SPARKLE_FEED_URL" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL $SPARKLE_FEED_URL" "$DIST/$APP_NAME/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Add :GTSourceCommit string $SOURCE_COMMIT" "$DIST/$APP_NAME/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :GTSourceDirty bool $SOURCE_DIRTY" "$DIST/$APP_NAME/Contents/Info.plist"

install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$DIST/$APP_NAME/Contents/MacOS/GlassTunnel" 2>/dev/null || true

for arch in "${REQUIRED_ARCHS[@]}"; do
  if [[ " $(/usr/bin/lipo -archs "$DIST/$APP_NAME/Contents/MacOS/GlassTunnel") " != *" $arch "* ]]; then
    echo "Packaged executable is missing required architecture $arch." >&2
    exit 1
  fi
done

echo "==> Signing ($SIGNING_MODE)"
[[ -f "$ENTITLEMENTS" ]] || { echo "Entitlements file not found: $ENTITLEMENTS" >&2; exit 1; }

if [[ "$SIGNING_MODE" == "ad-hoc" ]]; then
  SIGN_IDENTITY="-"
elif [[ "$SIGNING_MODE" == "local" ]]; then
  SIGN_IDENTITY="$LOCAL_SIGN_IDENTITY"
else
  SIGN_IDENTITY="$DEVELOPER_ID"
fi

TIMESTAMP_ARGS=()
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  TIMESTAMP_ARGS+=(--timestamp)
else
  TIMESTAMP_ARGS+=(--timestamp=none)
fi

echo "==> Signing embedded code"
codesign --force --options runtime "${TIMESTAMP_ARGS[@]}" \
  --sign "$SIGN_IDENTITY" \
  "$DIST/$APP_NAME/Contents/Frameworks/WebRTC.framework"
# Sparkle's helpers first, then the framework that contains them.
for sparkle_part in \
  "$SPARKLE_DEST/Versions/B/Autoupdate" \
  "$SPARKLE_DEST/Versions/B/Updater.app" \
  "$SPARKLE_DEST"; do
  codesign --force --options runtime "${TIMESTAMP_ARGS[@]}" --sign "$SIGN_IDENTITY" "$sparkle_part"
done
shopt -s nullglob
for dylib in "$DIST/$APP_NAME/Contents/Frameworks"/*.dylib; do
  codesign --force --options runtime "${TIMESTAMP_ARGS[@]}" --sign "$SIGN_IDENTITY" "$dylib"
done
shopt -u nullglob

APP_CODESIGN_ARGS=(
  --force
  --options runtime
  "${TIMESTAMP_ARGS[@]}"
  --entitlements "$ENTITLEMENTS"
  --sign "$SIGN_IDENTITY"
)
if [[ "$SIGNING_MODE" == "ad-hoc" ]]; then
  APP_CODESIGN_ARGS+=("-r=designated => identifier \"io.glasstunnel.host\"")
fi
codesign "${APP_CODESIGN_ARGS[@]}" \
  "$DIST/$APP_NAME"

codesign --verify --deep --strict --verbose=2 "$DIST/$APP_NAME"
codesign --verify --strict --verbose=2 \
  "$DIST/$APP_NAME/Contents/Frameworks/WebRTC.framework"
codesign --verify --deep --strict --verbose=2 "$SPARKLE_DEST"

if ! otool -L "$DIST/$APP_NAME/Contents/MacOS/GlassTunnel" | \
  grep -F '@rpath/WebRTC.framework/WebRTC' >/dev/null; then
  echo "Packaged executable does not link the embedded WebRTC framework through @rpath." >&2
  exit 1
fi
if ! otool -L "$DIST/$APP_NAME/Contents/MacOS/GlassTunnel" | \
  grep -F '@rpath/Sparkle.framework/Versions/B/Sparkle' >/dev/null; then
  echo "Packaged executable does not link the embedded Sparkle framework through @rpath." >&2
  exit 1
fi
if ! otool -l "$DIST/$APP_NAME/Contents/MacOS/GlassTunnel" | \
  grep -F 'path @executable_path/../Frameworks' >/dev/null; then
  echo "Packaged executable is missing the app Frameworks runtime search path." >&2
  exit 1
fi

echo "==> Packaged architectures: $(/usr/bin/lipo -archs "$DIST/$APP_NAME/Contents/MacOS/GlassTunnel")"
echo "==> Embedded WebRTC architectures: $(/usr/bin/lipo -archs "$DIST/$APP_NAME/Contents/Frameworks/WebRTC.framework/WebRTC")"
if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  echo "==> In-app updates: on (feed $(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$DIST/$APP_NAME/Contents/Info.plist"))"
else
  echo "==> In-app updates: off (no update public key; the app links to GitHub Releases)"
fi

echo "==> Creating DMG"
# The installer window: artwork, the app, and an Applications link to drag it to.
bash "$REPO/scripts/dmg/build-dmg.sh" "$DIST/$APP_NAME" "$DIST/$DMG_NAME"

if [[ "$SIGNING_MODE" != "ad-hoc" ]]; then
  codesign --force "${TIMESTAMP_ARGS[@]}" --sign "$SIGN_IDENTITY" "$DIST/$DMG_NAME"
else
  echo "==> Skipping DMG signing for ad-hoc build"
fi

if [[ "$NOTARIZE" == "1" ]]; then
  GT_NOTARY_PROFILE="$NOTARY_PROFILE" \
    GT_DEVELOPER_ID="$DEVELOPER_ID" \
    "$REPO/scripts/notarize-mac-release.sh" "$DIST/$DMG_NAME"
else
  echo "==> Skipping notarization"
fi

echo "==> Done"
echo "    $DIST/$APP_NAME"
echo "    $DIST/$DMG_NAME"
