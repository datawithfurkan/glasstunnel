#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/glasstunnel-codex-state-audit.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

APP_ROOT="$TMP_DIR/Applications"
CHATGPT_APP="$APP_ROOT/ChatGPT.app"
STATE_DIR="$TMP_DIR/codex-state"
mkdir -p "$CHATGPT_APP/Contents" "$STATE_DIR/sessions"

cat > "$CHATGPT_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.openai.codex</string>
  <key>CFBundleShortVersionString</key>
  <string>99.1</string>
  <key>CFBundleVersion</key>
  <string>123</string>
</dict>
</plist>
PLIST

run_audit() {
  CODEX_AUDIT_APP_SEARCH_DIRS="$1" \
  CODEX_AUDIT_NSWORKSPACE_RESULT="${2:-}" \
  CODEX_STATE_DIR="$STATE_DIR" \
    bash "$ROOT_DIR/scripts/codex-state-audit.sh"
}

installed_output="$(run_audit "$APP_ROOT")"
grep -Fq "Codex app: present: $CHATGPT_APP" <<<"$installed_output"
grep -Fq "Codex app version: 99.1 (123)" <<<"$installed_output"

cached_app="$TMP_DIR/Library/Caches/com.openai.ShipIt/update/ChatGPT.app"
mkdir -p "$cached_app/Contents"
cp "$CHATGPT_APP/Contents/Info.plist" "$cached_app/Contents/Info.plist"

cached_output="$(run_audit "$TMP_DIR/EmptyApplications" "$cached_app")"
grep -Fq "Codex app: missing" <<<"$cached_output"

echo "Codex state audit smoke passed."
