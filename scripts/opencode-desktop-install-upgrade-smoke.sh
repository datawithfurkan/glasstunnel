#!/usr/bin/env bash
# Smoke-test OpenCode Desktop install/reinstall/upgrade availability transitions
# without touching the real /Applications/OpenCode.app.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

APP_DIR="$TMP_DIR/Applications"
HOME_DIR="$TMP_DIR/home"
HOME_APP_DIR="$HOME_DIR/Applications"
BIN_DIR="$TMP_DIR/bin"
BASE_PATH="$BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$APP_DIR" "$HOME_APP_DIR" "$BIN_DIR"

run_audit() {
  GT_LOCAL_APP_SEARCH_DIRS="$APP_DIR:$HOME_APP_DIR" \
    GT_LOCAL_APP_USE_NSWORKSPACE=0 \
    HOME="$HOME_DIR" \
    PATH="$BASE_PATH" \
    bash "$ROOT_DIR/scripts/local-app-availability.sh"
}

assert_contains() {
  local output="$1"
  local needle="$2"
  if ! grep -Fq "$needle" <<<"$output"; then
    echo "Expected output to contain:" >&2
    echo "$needle" >&2
    echo >&2
    echo "Actual output:" >&2
    echo "$output" >&2
    exit 1
  fi
}

assert_not_contains() {
  local output="$1"
  local needle="$2"
  if grep -Fq "$needle" <<<"$output"; then
    echo "Expected output not to contain:" >&2
    echo "$needle" >&2
    echo >&2
    echo "Actual output:" >&2
    echo "$output" >&2
    exit 1
  fi
}

write_app_info_plist() {
  local app_path="$1"
  local bundle_id="$2"
  local version="$3"
  local contents_dir="$app_path/Contents"

  mkdir -p "$contents_dir/MacOS"
  cat > "$contents_dir/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>$bundle_id</string>
  <key>CFBundleShortVersionString</key>
  <string>$version</string>
</dict>
</plist>
EOF
}

write_fake_executable() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$path"
}

assert_version() {
  local app_path="$1"
  local expected="$2"
  local actual
  actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected $app_path version $expected, found $actual." >&2
    exit 1
  fi
}

echo "OpenCode Desktop install/upgrade availability smoke"
echo "Repo: $ROOT_DIR"
echo "Commit: $(git rev-parse --short HEAD 2>/dev/null || printf unknown)"
echo "Temp root: $TMP_DIR"
echo

echo "==> Missing OpenCode app and CLI"
output="$(run_audit)"
assert_contains "$output" "| OpenCode | missing: - | missing: - | do not publish |"

echo "==> Fresh Desktop install without prompt-capable CLI"
standard_app="$APP_DIR/OpenCode.app"
write_app_info_plist "$standard_app" "ai.opencode.desktop" "1.17.9"
assert_version "$standard_app" "1.17.9"
output="$(run_audit)"
assert_contains "$output" "| OpenCode | present: $standard_app (bundle ID ai.opencode.desktop) | missing: - | publish; available only when CLI exists |"

echo "==> Bad replacement does not publish as OpenCode"
rm -rf "$standard_app"
write_app_info_plist "$standard_app" "com.example.not-opencode" "9.99.0"
assert_version "$standard_app" "9.99.0"
output="$(run_audit)"
assert_contains "$output" "| OpenCode | present: $standard_app (bundle ID mismatch: com.example.not-opencode; expected ai.opencode.app,ai.opencode.desktop,dev.opencode.cli) | missing: - | do not publish; bundle ID mismatch |"

echo "==> Upgrade replacement with separate CLI stays CLI-backed"
rm -rf "$standard_app"
write_app_info_plist "$standard_app" "ai.opencode.desktop" "1.18.0"
write_fake_executable "$BIN_DIR/opencode"
assert_version "$standard_app" "1.18.0"
output="$(run_audit)"
assert_contains "$output" "| OpenCode | present: $standard_app (bundle ID ai.opencode.desktop) | present: $BIN_DIR/opencode | publish; available only when CLI exists |"
assert_not_contains "$output" "bundle ID mismatch"

echo "==> User Applications bundled CLI is recognized after replacement"
rm -rf "$standard_app"
rm -f "$BIN_DIR/opencode"
home_app="$HOME_APP_DIR/OpenCode.app"
write_app_info_plist "$home_app" "ai.opencode.desktop" "1.18.1"
write_fake_executable "$home_app/Contents/MacOS/opencode-cli"
assert_version "$home_app" "1.18.1"
output="$(run_audit)"
assert_contains "$output" "| OpenCode | present: $home_app (bundle ID ai.opencode.desktop) | present: $home_app/Contents/MacOS/opencode-cli | publish; available only when CLI exists |"

echo "==> Uninstall removes OpenCode publication"
rm -rf "$home_app"
output="$(run_audit)"
assert_contains "$output" "| OpenCode | missing: - | missing: - | do not publish |"

echo
echo "OpenCode Desktop install/upgrade availability smoke passed."
echo "This is isolated local evidence. It does not delete, replace, or launch the real /Applications/OpenCode.app."
