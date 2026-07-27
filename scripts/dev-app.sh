#!/usr/bin/env bash
# Build and launch an unsigned development .app bundle.
#
# Why: SwiftPM's raw executable has no bundle identifier, so every Xcode
# rebuild creates a "new" app from TCC's point of view, and Screen
# Recording / Accessibility permissions keep re-prompting. Wrapping the
# binary in a .app with a stable CFBundleIdentifier lets macOS attach
# the permission persistently.
#
# The script also copies WebRTC.framework into Contents/Frameworks/ and
# re-signs everything with matching entitlements so the hardened runtime
# accepts the nested framework.
#
# Usage:
#   bash scripts/dev-app.sh          # debug build
#   bash scripts/dev-app.sh release  # release build
set -euo pipefail

CONFIG="${1:-debug}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="$REPO/apps/host-macos"
APP_DIR="${GLASSTUNNEL_DEV_APP_PATH:-$HOME/Applications/Glasstunnel-Dev.app}"
BUNDLE_ID="${GLASSTUNNEL_DEV_BUNDLE_ID:-io.glasstunnel.host.dev}"
DISPLAY_NAME="${GLASSTUNNEL_DEV_DISPLAY_NAME:-Glasstunnel Dev}"
KEYCHAIN_SUFFIX="${GLASSTUNNEL_KEYCHAIN_SUFFIX:-}"
if [[ "$CONFIG" == "--print-bundle-id" ]]; then
  printf '%s\n' "$BUNDLE_ID"
  exit 0
fi
if [[ -n "$KEYCHAIN_SUFFIX" ]]; then
  KEYCHAIN_SUFFIX="$(printf '%s' "$KEYCHAIN_SUFFIX" | tr -c 'A-Za-z0-9._-' '_')"
  KEYCHAIN_SUFFIX="${KEYCHAIN_SUFFIX:0:64}"
fi
WEB_APP_URL="${GLASSTUNNEL_WEB_APP_URL:-}"
SIGNALING_URL="${GLASSTUNNEL_SIGNALING_URL:-}"
DEV_KEY_FILE="${GLASSTUNNEL_DEV_DEVICE_KEY_FILE:-}"
DEVICE_REGISTRY_FILE="${GLASSTUNNEL_DEVICE_REGISTRY_FILE:-}"
SWIFT_SCRATCH_PATH="${GLASSTUNNEL_SWIFT_SCRATCH_PATH:-}"
xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}
if [[ -n "$WEB_APP_URL" ]]; then
  WEB_APP_URL="$(xml_escape "$WEB_APP_URL")"
fi
if [[ -n "$SIGNALING_URL" ]]; then
  SIGNALING_URL="$(xml_escape "$SIGNALING_URL")"
fi
if [[ -n "$DEV_KEY_FILE" ]]; then
  DEV_KEY_FILE="$(xml_escape "$DEV_KEY_FILE")"
fi
if [[ -n "$DEVICE_REGISTRY_FILE" ]]; then
  DEVICE_REGISTRY_FILE="$(xml_escape "$DEVICE_REGISTRY_FILE")"
fi
BUNDLE_ID_PLIST="$(xml_escape "$BUNDLE_ID")"
DISPLAY_NAME_PLIST="$(xml_escape "$DISPLAY_NAME")"

echo "==> Building ($CONFIG)"
cd "$HOST"
SWIFT_BUILD_ARGS=(-c "$CONFIG")
if [[ -n "$SWIFT_SCRATCH_PATH" ]]; then
  mkdir -p "$SWIFT_SCRATCH_PATH"
  SWIFT_BUILD_ARGS+=(--scratch-path "$SWIFT_SCRATCH_PATH")
fi
swift build "${SWIFT_BUILD_ARGS[@]}"

BUILD_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
BIN="$BUILD_DIR/GlassTunnel"
if [[ ! -x "$BIN" ]]; then
  echo "error: binary not found at $BIN" >&2
  exit 1
fi
if [[ ! -d "$BUILD_DIR/WebRTC.framework" ]]; then
  echo "error: WebRTC.framework not found alongside the binary at $BUILD_DIR" >&2
  echo "       this usually means SwiftPM moved its layout; inspect $BUILD_DIR manually." >&2
  exit 1
fi

# Kill only the copy installed at this bundle path. Other Glasstunnel builds
# may be running with different account and endpoint configuration.
APP_EXECUTABLE="$APP_DIR/Contents/MacOS/GlassTunnel"
while IFS= read -r pid; do
  [[ -n "$pid" ]] || continue
  process_command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  process_command="${process_command#"${process_command%%[![:space:]]*}"}"
  if [[ "$process_command" == "$APP_EXECUTABLE" ]]; then
    kill "$pid" 2>/dev/null || true
  fi
done < <(pgrep -x GlassTunnel 2>/dev/null || true)
sleep 0.3

echo "==> Assembling $APP_DIR"
mkdir -p "$(dirname "$APP_DIR")"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

cp "$BIN" "$APP_DIR/Contents/MacOS/GlassTunnel"
cp "$HOST/Metadata/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -R "$BUILD_DIR/WebRTC.framework" "$APP_DIR/Contents/Frameworks/"

# Any Swift standard-library dylibs we linked dynamically need to come
# with us. Most of Swift is resolved via /usr/lib/swift at runtime on
# macOS 12+, but if SPM dropped any .dylib in BUILD_DIR we ship those too.
shopt -s nullglob
for dylib in "$BUILD_DIR"/*.dylib; do
  cp "$dylib" "$APP_DIR/Contents/Frameworks/"
done
shopt -u nullglob

echo "==> Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>           <string>GlassTunnel</string>
  <key>CFBundleIdentifier</key>           <string>${BUNDLE_ID_PLIST}</string>
  <key>CFBundleIconFile</key>             <string>AppIcon</string>
  <key>CFBundleName</key>                 <string>${DISPLAY_NAME_PLIST}</string>
  <key>CFBundleDisplayName</key>          <string>${DISPLAY_NAME_PLIST}</string>
  <key>CFBundleShortVersionString</key>   <string>0.1.0-dev</string>
  <key>CFBundleVersion</key>              <string>1</string>
  <key>CFBundlePackageType</key>          <string>APPL</string>
  <key>LSMinimumSystemVersion</key>       <string>13.0</string>
  <key>NSHighResolutionCapable</key>      <true/>
  <key>LSEnvironment</key>
  <dict>
	    <key>GLASSTUNNEL_DEV</key>            <string>1</string>
$(if [[ -n "$WEB_APP_URL" ]]; then
cat <<EOF
	    <key>GLASSTUNNEL_WEB_APP_URL</key>    <string>${WEB_APP_URL}</string>
EOF
fi)
$(if [[ -n "$SIGNALING_URL" ]]; then
cat <<EOF
	    <key>GLASSTUNNEL_SIGNALING_URL</key>  <string>${SIGNALING_URL}</string>
EOF
fi)
$(if [[ -n "$KEYCHAIN_SUFFIX" ]]; then
cat <<EOF
	    <key>GLASSTUNNEL_KEYCHAIN_SUFFIX</key> <string>${KEYCHAIN_SUFFIX}</string>
EOF
fi)
$(if [[ -n "$DEV_KEY_FILE" ]]; then
cat <<EOF
	    <key>GLASSTUNNEL_DEV_DEVICE_KEY_FILE</key> <string>${DEV_KEY_FILE}</string>
EOF
fi)
$(if [[ -n "$DEVICE_REGISTRY_FILE" ]]; then
cat <<EOF
	    <key>GLASSTUNNEL_DEVICE_REGISTRY_FILE</key> <string>${DEVICE_REGISTRY_FILE}</string>
EOF
fi)
  </dict>
  <key>NSScreenCaptureUsageDescription</key>
    <string>Glasstunnel captures the specific windows you pick (never the whole screen) and streams them to your signed-in devices.</string>
  <key>NSAccessibilityUsageDescription</key>
    <string>Glasstunnel targets the chat input of your local AI coding agents so prompts you type on your phone land in the right place.</string>
</dict>
</plist>
PLIST

echo "==> Fixing rpath"
# Point the binary at ../Frameworks/ for WebRTC.framework resolution.
# The binary already carries @loader_path as an rpath (which resolved to
# BUILD_DIR when running via swift run); we ADD @executable_path/../Frameworks
# so the bundled layout also works. We ignore errors because install_name_tool
# refuses to add a duplicate rpath and we don't care if it's already there.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/GlassTunnel" 2>/dev/null || true

ENTITLEMENTS="$(mktemp -t glasstunnel-ent).plist"
cat > "$ENTITLEMENTS" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.disable-library-validation</key> <true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key> <true/>
  <key>com.apple.security.cs.allow-jit</key> <true/>
  <key>com.apple.security.device.screen-capture</key> <true/>
</dict>
</plist>
ENT

# Pick the best available signing identity. A stable signing identity gives
# TCC something persistent to attach Screen Recording / Accessibility grants to.
IDENTITY=""
IDENTITY_SOURCE=""
for search in "Apple Development" "Mac Developer" "Developer ID Application"; do
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '"' -v s="$search" 'index($0, s) { print $2; exit }')
  if [[ -n "$IDENTITY" ]]; then
    IDENTITY_SOURCE="apple"
    break
  fi
done
if [[ -z "$IDENTITY" ]]; then
  if [[ "${GLASSTUNNEL_DISABLE_LOCAL_DEV_CODESIGN:-0}" != "1" ]] \
    && [[ -x "$REPO/scripts/ensure-dev-codesign-identity.sh" ]]; then
    if IDENTITY="$("$REPO/scripts/ensure-dev-codesign-identity.sh")"; then
      IDENTITY_SOURCE="local"
    else
      IDENTITY=""
      echo "==> Local development signing identity unavailable; using ad-hoc signing"
    fi
  else
    echo "==> No Apple signing identity found; using ad-hoc signing"
    echo "   (local development signing helper disabled)"
  fi
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  IDENTITY_SOURCE="adhoc"
  echo "==> No certificate signing identity found; using ad-hoc signing"
  echo "   TCC grants may need to be reset/re-granted after rebuilds."
elif [[ "$IDENTITY_SOURCE" == "local" ]]; then
  echo "==> Signing with local development identity: $IDENTITY"
else
  echo "==> Signing with identity: $IDENTITY"
fi

echo "==> Signing WebRTC.framework"
codesign --force --sign "$IDENTITY" --options runtime \
  --timestamp=none \
  "$APP_DIR/Contents/Frameworks/WebRTC.framework"

echo "==> Signing app bundle"
APP_CODESIGN_ARGS=(
  --force
  --sign "$IDENTITY"
  --options runtime
  --timestamp=none
  --entitlements "$ENTITLEMENTS"
)
if [[ "$IDENTITY_SOURCE" == "adhoc" ]]; then
  APP_CODESIGN_ARGS+=("-r=designated => identifier \"$BUNDLE_ID\"")
fi
codesign "${APP_CODESIGN_ARGS[@]}" "$APP_DIR"

rm -f "$ENTITLEMENTS"

# Verify signature so a launch-time rejection surfaces as a script error
# rather than an opaque "cannot be opened" dialog.
echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_DIR" 2>&1 | tail -5

echo ""
echo "==> Launching"
export GLASSTUNNEL_DEV=1
open "$APP_DIR"

echo ""
echo "App installed at: $APP_DIR"
echo "Bundle ID:         $BUNDLE_ID"
echo ""
echo "If macOS asks for Screen Recording / Accessibility, grant them to"
if [[ "$IDENTITY_SOURCE" == "adhoc" ]]; then
  echo "'$DISPLAY_NAME' in System Settings. This build is ad-hoc signed,"
  echo "so macOS may treat rebuilds as new apps."
else
  echo "'$DISPLAY_NAME' in System Settings. This dev bundle is signed with"
  echo "a stable local identity so grants survive normal rebuilds."
fi
