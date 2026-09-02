#!/usr/bin/env bash
# Smoke-test local app availability reporting with isolated fake installs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

APP_DIR="$TMP_DIR/Applications"
BIN_DIR="$TMP_DIR/bin"
HOME_DIR="$TMP_DIR/home"
BASE_PATH="$BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$APP_DIR" "$BIN_DIR" "$HOME_DIR"

run_audit() {
  GT_LOCAL_APP_SEARCH_DIRS="$APP_DIR" \
    GT_LOCAL_APP_USE_NSWORKSPACE=0 \
    HOME="$HOME_DIR" \
    PATH="$BASE_PATH" \
    bash "$ROOT_DIR/scripts/local-app-availability.sh"
}

run_nsworkspace_audit() {
  GT_LOCAL_APP_SEARCH_DIRS="$APP_DIR" \
    GT_LOCAL_APP_USE_NSWORKSPACE=1 \
    GT_LOCAL_APP_NSWORKSPACE_RESULT="$1" \
    HOME="$HOME_DIR" \
    PATH="$BASE_PATH" \
    bash "$ROOT_DIR/scripts/local-app-availability.sh"
}

assert_contains() {
  local output="$1"
  local needle="$2"
  if ! grep -Fq "$needle" <<< "$output"; then
    echo "Expected availability audit to contain:" >&2
    echo "$needle" >&2
    echo >&2
    echo "Actual output:" >&2
    echo "$output" >&2
    exit 1
  fi
}

write_app_info_plist() {
  local app_name="$1"
  local bundle_id="$2"
  local contents_dir="$APP_DIR/$app_name.app/Contents"

  mkdir -p "$contents_dir"
  cat > "$contents_dir/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>$bundle_id</string>
</dict>
</plist>
EOF
}

output="$(run_audit)"
assert_contains "$output" "| Claude Code | - | missing: - | do not publish |"
assert_contains "$output" "| Gemini CLI | - | missing: - | do not publish |"
assert_contains "$output" "| OpenCode | missing: - | missing: - | do not publish |"

SHIPIT_CURSOR="$HOME_DIR/Library/Caches/com.cursor.ShipIt/update/Cursor.app"
mkdir -p "$SHIPIT_CURSOR/Contents"
cat > "$SHIPIT_CURSOR/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.todesktop.230313mzl4w4u92</string></dict></plist>
EOF
output="$(run_nsworkspace_audit "$SHIPIT_CURSOR")"
assert_contains "$output" "| Cursor | missing: - | - | do not publish unless a Cursor window is detected |"

write_app_info_plist "Claude" "com.anthropic.claudefordesktop"
write_app_info_plist "OpenCode" "com.example.not-opencode"
output="$(run_audit)"
# An installed Claude desktop app never makes the CLI card publishable.
assert_contains "$output" "| Claude Code | - | missing: - | do not publish |"
assert_contains "$output" "| OpenCode | present: $APP_DIR/OpenCode.app (bundle ID mismatch: com.example.not-opencode; expected ai.opencode.app,ai.opencode.desktop,dev.opencode.cli) | missing: - | do not publish; bundle ID mismatch |"

rm -rf "$APP_DIR/Claude.app" "$APP_DIR/OpenCode.app"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN_DIR/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN_DIR/gemini"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN_DIR/opencode"
chmod +x "$BIN_DIR/claude" "$BIN_DIR/gemini" "$BIN_DIR/opencode"

output="$(run_audit)"
assert_contains "$output" "| Claude Code | - | present: $BIN_DIR/claude | publish as available |"
assert_contains "$output" "| Gemini CLI | - | present: $BIN_DIR/gemini | publish as available |"
assert_contains "$output" "| OpenCode | missing: - | present: $BIN_DIR/opencode | publish; available only when CLI exists |"

rm -f "$BIN_DIR/opencode"
mkdir -p "$HOME_DIR/.volta/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME_DIR/.volta/bin/opencode"
chmod +x "$HOME_DIR/.volta/bin/opencode"

output="$(run_audit)"
assert_contains "$output" "| OpenCode | missing: - | present: $HOME_DIR/.volta/bin/opencode | publish; available only when CLI exists |"

echo "Local app availability smoke passed."
