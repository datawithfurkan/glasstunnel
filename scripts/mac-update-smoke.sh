#!/usr/bin/env bash
# Proves the in-app update path end to end on this Mac, without the release key
# or the real app: a throwaway app embeds and signs Sparkle the way
# build-app.sh does, version 1.0.0 reads a signed feed served from 127.0.0.1,
# downloads the EdDSA-signed 1.0.1 DMG, installs it over itself and relaunches.
# A second copy reads the same feed with its release notes altered after signing
# and must refuse it.
#
# Uses a temporary Ed25519 key file (never the Keychain), a temporary
# directory, and the bundle ID io.glasstunnel.update-smoke. Nothing is left
# behind. It does not prove Developer ID signing or notarization.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="$ROOT_DIR/apps/host-macos"
SPARKLE_ROOT="$HOST/.build/artifacts/sparkle/Sparkle"
SPARKLE_FRAMEWORK="$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ENTITLEMENTS="$HOST/Metadata/entitlements.plist"
TIMEOUT_SECONDS="${GT_UPDATE_SMOKE_TIMEOUT:-120}"
OLD_VERSION="1.0.0"
NEW_VERSION="1.0.1"
BUNDLE_ID="io.glasstunnel.update-smoke"

if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  swift package resolve --package-path "$HOST" >/dev/null
fi
[[ -d "$SPARKLE_FRAMEWORK" ]] || { echo "Sparkle.framework not found at $SPARKLE_FRAMEWORK" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/glasstunnel-update-smoke.XXXXXX")"
SERVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  # The smoke app quits itself; ask by bundle ID in case it timed out.
  osascript -e "if application id \"$BUNDLE_ID\" is running then tell application id \"$BUNDLE_ID\" to quit" \
    >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
FEED_URL="http://127.0.0.1:$PORT/appcast.xml"
mkdir -p "$WORK/www" "$WORK/build" "$WORK/installed"

echo "==> Creating a temporary update key"
KEYS="$(node -e '
  const { generateKeyPairSync } = require("node:crypto");
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const seed = Buffer.from(privateKey.export({ format: "jwk" }).d, "base64url").toString("base64");
  const pub = Buffer.from(publicKey.export({ format: "jwk" }).x, "base64url").toString("base64");
  console.log(seed + " " + pub);
')"
PRIVATE_KEY_FILE="$WORK/private-key"
printf '%s' "${KEYS% *}" >"$PRIVATE_KEY_FILE"
chmod 600 "$PRIVATE_KEY_FILE"
PUBLIC_KEY="${KEYS#* }"

echo "==> Building the smoke app"
swiftc -O -F "$(dirname "$SPARKLE_FRAMEWORK")" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$ROOT_DIR/scripts/mac-update-smoke/main.swift" -o "$WORK/build/UpdateSmoke"

make_app() {
  local version="$1" app="$2" feed_url="$3" status="$4"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
  cp "$WORK/build/UpdateSmoke" "$app/Contents/MacOS/UpdateSmoke"
  ditto "$SPARKLE_FRAMEWORK" "$app/Contents/Frameworks/Sparkle.framework"
  rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
    "$app/Contents/Frameworks/Sparkle.framework/XPCServices"
  cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>UpdateSmoke</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>UpdateSmoke</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>SUFeedURL</key><string>$feed_url</string>
  <key>SUPublicEDKey</key><string>$PUBLIC_KEY</string>
  <key>SURequireSignedFeed</key><true/>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SUEnableAutomaticChecks</key><false/>
  <key>GTSmokeStatusFile</key><string>$status</string>
  <key>GTSmokeTargetVersion</key><string>$NEW_VERSION</string>
</dict>
</plist>
PLIST
  # The same order as build-app.sh: Sparkle's helpers, the framework, the app.
  local framework="$app/Contents/Frameworks/Sparkle.framework"
  for part in "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app" "$framework"; do
    codesign --force --options runtime --timestamp=none --sign - "$part" 2>/dev/null
  done
  codesign --force --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" \
    --sign - "-r=designated => identifier \"$BUNDLE_ID\"" "$app" 2>/dev/null
  codesign --verify --deep --strict "$app"
}

make_app "$OLD_VERSION" "$WORK/installed/UpdateSmoke.app" "$FEED_URL" "$WORK/status.log"
make_app "$OLD_VERSION" "$WORK/tampered/UpdateSmoke.app" "http://127.0.0.1:$PORT/appcast-tampered.xml" "$WORK/tampered.log"
make_app "$NEW_VERSION" "$WORK/build/dmg-root/UpdateSmoke.app" "$FEED_URL" "$WORK/status.log"
ln -s /Applications "$WORK/build/dmg-root/Applications"
hdiutil create -quiet -volname "UpdateSmoke" -srcfolder "$WORK/build/dmg-root" -ov -format UDZO "$WORK/www/UpdateSmoke-$NEW_VERSION.dmg"

echo "==> Writing the signed feed"
cat >"$WORK/CHANGELOG.md" <<'NOTES'
# Changelog

## 1.0.1 - Smoke

- The update smoke installed this version.
NOTES
GT_SPARKLE_PRIVATE_KEY_FILE="$PRIVATE_KEY_FILE" node "$ROOT_DIR/scripts/sparkle-appcast.mjs" \
  "$NEW_VERSION" "$WORK/www/UpdateSmoke-$NEW_VERSION.dmg" \
  --out "$WORK/www/appcast.xml" \
  --changelog "$WORK/CHANGELOG.md" \
  --download-url "http://127.0.0.1:$PORT/UpdateSmoke-$NEW_VERSION.dmg"
sed 's/The update smoke installed this version./Altered after signing./' \
  "$WORK/www/appcast.xml" >"$WORK/www/appcast-tampered.xml"
cmp -s "$WORK/www/appcast.xml" "$WORK/www/appcast-tampered.xml" && { echo "Could not alter the feed copy." >&2; exit 1; }

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/www" >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -fsS "$FEED_URL" >/dev/null 2>&1 && break
  sleep 0.1
done

# Launches an app copy and waits until it reaches the new version or gives up.
run_app() {
  local app="$1" status="$2" deadline=$((SECONDS + TIMEOUT_SECONDS))
  open -n "$app"
  while (( SECONDS < deadline )); do
    grep -q -E "^(running $NEW_VERSION|error|no-update)" "$status" 2>/dev/null && break
    sleep 1
  done
  # Let the finished instance quit before the next copy (same bundle ID) starts.
  sleep 2
  echo "--- $(basename "$status")"
  cat "$status" 2>/dev/null || echo "(no status written)"
}

app_version() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"
}

FAILED=0
echo "==> A feed altered after signing must be refused"
run_app "$WORK/tampered/UpdateSmoke.app" "$WORK/tampered.log"
if [[ "$(app_version "$WORK/tampered/UpdateSmoke.app")" == "$OLD_VERSION" ]] && grep -q "^error" "$WORK/tampered.log"; then
  echo "Refused the altered feed and stayed on $OLD_VERSION."
else
  echo "The altered feed was not refused." >&2
  FAILED=1
fi

echo "==> $OLD_VERSION must install $NEW_VERSION from the signed feed and relaunch"
run_app "$WORK/installed/UpdateSmoke.app" "$WORK/status.log"
if grep -q "^running $NEW_VERSION$" "$WORK/status.log" 2>/dev/null \
  && [[ "$(app_version "$WORK/installed/UpdateSmoke.app")" == "$NEW_VERSION" ]]; then
  codesign --verify --deep --strict "$WORK/installed/UpdateSmoke.app"
  echo "Installed $NEW_VERSION and relaunched."
else
  echo "The app on disk is $(app_version "$WORK/installed/UpdateSmoke.app")." >&2
  FAILED=1
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo "Update smoke failed." >&2
  echo "--- feed server" >&2
  cat "$WORK/server.log" >&2 || true
  exit 1
fi
echo "Update smoke passed."
