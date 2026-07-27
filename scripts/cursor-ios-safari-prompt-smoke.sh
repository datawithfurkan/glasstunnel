#!/usr/bin/env bash
# Verify hosted iOS Simulator Safari can open Cursor, submit one bounded prompt,
# and that the real Cursor window shows the marker as both prompt and response.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$ROOT_DIR/.env.smoke.local" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT_DIR/.env.smoke.local"
  set +a
fi

OUT_DIR="${GT_CURSOR_IOS_OUT_DIR:-/tmp/glasstunnel-cursor-ios-safari}"
APP_URL="${GT_CURSOR_IOS_APP_URL:-https://app.glasstunnel.io}"
REMOTE_APP_ID="${GT_CURSOR_IOS_REMOTE_APP_ID:-cursor}"
case "$REMOTE_APP_ID" in
  cursor)
    REMOTE_APP_LABEL="Cursor"
    ;;
  cursor-agent)
    REMOTE_APP_LABEL="Cursor Agent"
    ;;
  *)
    echo "Result: failed; unsupported GT_CURSOR_IOS_REMOTE_APP_ID: $REMOTE_APP_ID" >&2
    exit 1
    ;;
esac
URL="${GT_CURSOR_IOS_URL:-$APP_URL/?app=$REMOTE_APP_ID&cursorIosPromptSmoke=$(date +%Y%m%d%H%M%S)}"
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
ARTIFACT_PATH="${GT_CURSOR_IOS_ARTIFACT:-$OUT_DIR/cursor-ios-safari-prompt-$RUN_STAMP.json}"
WAIT_SECONDS="${GT_CURSOR_IOS_WAIT:-10}"
START_WAIT_SECONDS="${GT_CURSOR_IOS_START_WAIT:-18}"
SUBMITTED_WAIT_SECONDS="${GT_CURSOR_IOS_SUBMITTED_WAIT:-2}"
RESPONSE_WAIT_SECONDS="${GT_CURSOR_IOS_RESPONSE_WAIT:-90}"
LINK_WAIT_SECONDS="${GT_CURSOR_IOS_LINK_WAIT:-10}"
DEVICE="${GT_CURSOR_IOS_DEVICE:-${GT_MOBILE_QA_DEVICE:-}}"
START_HOST_HARNESS="${GT_CURSOR_IOS_START_HOST:-1}"
FORCE_TEMP_HOST="${GT_CURSOR_IOS_FORCE_TEMP_HOST:-1}"
PREFLIGHT_ONLY="${GT_CURSOR_IOS_PREFLIGHT_ONLY:-0}"
BACKGROUND_PREFLIGHT_ONLY="${GT_CURSOR_IOS_BACKGROUND_PREFLIGHT_ONLY:-0}"
REQUIRE_ALLOWED_MODEL_SETTINGS="${GT_CURSOR_REQUIRE_ALLOWED_MODEL_SETTINGS:-1}"
ALLOWED_MODEL_SETTINGS="${GT_CURSOR_ALLOWED_MODEL_SETTINGS:-Composer 2.5 Fast}"
MODEL_SETTINGS_OVERRIDE_REASON="${GT_CURSOR_MODEL_SETTINGS_OVERRIDE_REASON:-}"
MODEL_SETTINGS_OVERRIDE_SOURCE="${GT_CURSOR_MODEL_SETTINGS_OVERRIDE_SOURCE:-}"
AUTO_SIGN_IN="${GT_CURSOR_IOS_AUTO_SIGN_IN:-1}"
SMOKE_EMAIL="${SMOKE_EMAIL:-}"
SMOKE_PASSWORD="${SMOKE_PASSWORD:-}"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:cursor:ios-safari-prompt

Opens the hosted Cursor view in iOS Simulator Safari, links a temporary local
host when possible, starts Cursor from the rendered mobile UI, sends one small
marker prompt, OCRs the Simulator frames, and verifies through Accessibility
that the real Cursor window contains the marker as both prompt and response.
With GT_CURSOR_IOS_REMOTE_APP_ID=cursor-agent, opens the Cursor Agent command
surface instead and verifies the rendered Safari command output, not the
desktop Cursor window.

This is iOS Simulator Safari evidence. It can consume a small amount of Cursor
model quota. Use the lowest-cost fast Cursor setting available.

Environment:
  GT_CURSOR_IOS_DEVICE          Simulator UDID. Defaults to GT_MOBILE_QA_DEVICE
                                or the first booted/available iPhone.
  GT_CURSOR_IOS_URL             Full URL to open.
  GT_CURSOR_IOS_WAIT            Seconds to wait before interaction. Default: 10.
  GT_CURSOR_IOS_START_WAIT      Seconds to wait after Start/Open. Default: 18.
  GT_CURSOR_IOS_SUBMITTED_WAIT  Seconds to wait after send before capture.
                                Default: 2.
  GT_CURSOR_IOS_RESPONSE_WAIT   Seconds to wait for Cursor response marker.
                                Default: 90.
  GT_CURSOR_IOS_ARTIFACT        JSON artifact path.
  GT_CURSOR_IOS_OUT_DIR         Artifact directory.
  GT_CURSOR_IOS_MARKER          Override the OCR-safe marker.
  GT_CURSOR_IOS_PROMPT          Override the prompt sent to Cursor.
  GT_CURSOR_IOS_REMOTE_APP_ID   Remote app to test: cursor or cursor-agent.
                                Default: cursor.
  GT_CURSOR_IOS_PREFLIGHT_ONLY=1
                                Stop after verifying the visible Cursor
                                model/settings preflight. Does not type or
                                send a prompt.
  GT_CURSOR_IOS_BACKGROUND_PREFLIGHT_ONLY=1
                                Stop after verifying model/settings, background
                                Safari through Settings, foreground Safari
                                again, and verify the Cursor surface recovers.
                                Does not type or send a prompt.
  GT_CURSOR_ALLOWED_MODEL_SETTINGS
                                Comma-separated allowed Cursor settings before
                                Send. Default: Composer 2.5 Fast.
  GT_CURSOR_REQUIRE_ALLOWED_MODEL_SETTINGS=0
                                Allow prompt submission without automated
                                model/settings verification. Requires
                                GT_CURSOR_MODEL_SETTINGS_OVERRIDE_REASON.
  GT_CURSOR_MODEL_SETTINGS_OVERRIDE_REASON
                                Short reason for bypassing automated
                                model/settings verification, for example
                                human-confirmed visible Composer 2.5 Fast.
  GT_CURSOR_MODEL_SETTINGS_OVERRIDE_SOURCE
                                Optional source for the override, such as
                                storage audit plus human visible check.
  GT_CURSOR_IOS_START_HOST=0    Do not start a temporary local host harness.
  GT_CURSOR_IOS_FORCE_TEMP_HOST=0
                                Do not navigate from an existing workspace to
                                the temporary linked host.
  GT_CURSOR_IOS_AUTO_SIGN_IN=0  Do not use SMOKE_EMAIL/SMOKE_PASSWORD to sign
                                Simulator Safari in when the hosted auth screen
                                is visible. Default: 1.
  SMOKE_EMAIL / SMOKE_PASSWORD  Email auth credentials for Simulator Safari
                                auto sign-in. Usually loaded from
                                .env.smoke.local when present.
  GT_CURSOR_IOS_EMAIL_X/Y       Override click ratios for the email input.
  GT_CURSOR_IOS_EMAIL_CONTINUE_X/Y
                                Override click ratios for Continue with email.
  GT_CURSOR_IOS_PASSWORD_X/Y    Override click ratios for the password input.
  GT_CURSOR_IOS_SIGNIN_X/Y      Override click ratios for the final Sign in.
  GT_CURSOR_IOS_OPEN_HOST_X/Y   Override click ratios for the host Open button.
  GT_CURSOR_IOS_START_X/Y       Override click ratios for Start/Open on Mac.
  GT_CURSOR_IOS_COMPOSER_X/Y    Override click ratios for the prompt composer.
  GT_CURSOR_IOS_SEND_X/Y        Override click ratios for the send button.
USAGE
}

if [[ "${1:-}" == "--" ]]; then
  shift
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Result: blocked; Cursor iOS Safari smoke requires macOS." >&2
  exit 1
fi

if [[ "$REMOTE_APP_ID" == "cursor" && ! -d "/Applications/Cursor.app" && ! -d "$HOME/Applications/Cursor.app" ]]; then
  echo "Result: blocked; Cursor.app is not installed." >&2
  exit 1
fi
if [[ "$REMOTE_APP_ID" == "cursor-agent" ]] &&
  [[ ! -x "${GT_CURSOR_AGENT_PATH:-$HOME/.local/bin/cursor-agent}" ]] &&
  ! command -v cursor-agent >/dev/null 2>&1; then
  echo "Result: blocked; standalone cursor-agent executable is not available." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

write_preflight_artifact() {
  local result="$1"
  local error_message="$2"
  local phase="$3"
  python3 - "$ARTIFACT_PATH" <<'PY' \
    "$result" \
    "$error_message" \
    "$phase" \
    "${DEVICE:-}" \
    "${state:-unknown}" \
    "$URL" \
    "$REMOTE_APP_ID" \
    "$START_HOST_HARNESS" \
    "$FORCE_TEMP_HOST" \
    "$REQUIRE_ALLOWED_MODEL_SETTINGS" \
    "$ALLOWED_MODEL_SETTINGS" \
    "$MODEL_SETTINGS_OVERRIDE_REASON" \
    "$MODEL_SETTINGS_OVERRIDE_SOURCE"
import json
import sys
from datetime import datetime, timezone

(
    artifact_path,
    result,
    error_message,
    phase,
    device,
    device_state,
    url,
    remote_app_id,
    start_host_harness,
    force_temp_host,
    require_allowed_model_settings,
    allowed_model_settings,
    model_settings_override_reason,
    model_settings_override_source,
) = sys.argv[1:]

payload = {
    "result": result,
    "error": error_message or None,
    "phase": phase,
    "device": device or None,
    "deviceState": device_state or None,
    "url": url,
    "remoteAppId": remote_app_id,
    "startHostHarness": start_host_harness == "1",
    "forceTempHost": force_temp_host == "1",
    "requireAllowedModelSettings": require_allowed_model_settings != "0",
    "allowedModelSettings": [value.strip() for value in allowed_model_settings.split(",") if value.strip()],
    "modelSettingsOverrideReason": model_settings_override_reason or None,
    "modelSettingsOverrideSource": model_settings_override_source or None,
    "modelSettingsOverrideUsed": False,
    "createdAt": datetime.now(timezone.utc).isoformat(),
}

with open(artifact_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

if [[ -z "$DEVICE" ]]; then
  visible_simulator_name="$(
    osascript 2>/dev/null <<'OSA' || true
tell application "System Events"
  tell process "Simulator"
    if (count of windows) is 0 then return ""
    set windowName to name of window 1
    set AppleScript's text item delimiters to " – "
    set parts to text items of windowName
    set AppleScript's text item delimiters to ""
    return item 1 of parts
  end tell
end tell
OSA
  )"
  DEVICE="$(
    VISIBLE_SIMULATOR_NAME="$visible_simulator_name" python3 <<'PY'
import json
import os
import subprocess
import sys

def load(args):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", *args, "-j"], text=True)).get("devices", {})

visible_name = os.environ.get("VISIBLE_SIMULATOR_NAME", "").strip()
if visible_name:
    for runtime_devices in load(["booted"]).values():
        for device in runtime_devices:
            if device.get("state") == "Booted" and device.get("name") == visible_name:
                print(device["udid"])
                sys.exit(0)

for runtime_devices in load(["booted"]).values():
    for device in runtime_devices:
        if device.get("state") == "Booted" and "iPhone" in device.get("name", ""):
            print(device["udid"])
            sys.exit(0)

for runtime_devices in load(["available"]).values():
    for device in runtime_devices:
        if device.get("isAvailable") and "iPhone" in device.get("name", ""):
            print(device["udid"])
            sys.exit(0)

sys.exit("No available iPhone simulator found.")
PY
  )"
fi

state="$(
  python3 - "$DEVICE" <<'PY'
import json
import subprocess
import sys

target = sys.argv[1]
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"], text=True)).get("devices", {})
for runtime_devices in data.values():
    for device in runtime_devices:
        if device.get("udid") == target:
            print(device.get("state", "Unknown"))
            sys.exit(0)
print("Unknown")
PY
)"

if [[ "$state" != "Booted" ]]; then
  echo "Booting iOS simulator $DEVICE..."
  xcrun simctl boot "$DEVICE"
fi

xcrun simctl bootstatus "$DEVICE" -b
state="Booted"
open -a Simulator

if ! window_geometry="$(
  osascript 2>&1 <<'OSA'
tell application "System Events"
  tell process "Simulator"
    if (count of windows) is 0 then error "Simulator has no visible window"
    set p to position of window 1
    set s to size of window 1
    return (item 1 of p as text) & "," & (item 2 of p as text) & "," & (item 1 of s as text) & "," & (item 2 of s as text)
  end tell
end tell
OSA
)"; then
  write_preflight_artifact failed "$window_geometry" "simulator-window-preflight"
  echo "Result: failed; Simulator is booted but no visible window is available for click/type automation." >&2
  echo "Open the Simulator device window, then rerun this smoke." >&2
  echo "Artifact: $ARTIFACT_PATH" >&2
  exit 1
fi

IFS=',' read -r window_x window_y window_w window_h <<<"$window_geometry"

click_helper="$(mktemp -t glasstunnel-ios-click.XXXXXX.swift)"
probe_file="$(mktemp -t glasstunnel-cursor-window-probe.XXXXXX.swift)"
cat >"$click_helper" <<'SWIFT'
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2]) else {
    fputs("usage: click x y\n", stderr)
    exit(2)
}

let point = CGPoint(x: x, y: y)
let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
down?.post(tap: .cghidEventTap)
usleep(50_000)
up?.post(tap: .cghidEventTap)
SWIFT

cat >"$probe_file" <<'SWIFT'
import AppKit
import ApplicationServices
import Foundation

let bundleID = "com.todesktop.230313mzl4w4u92"
let marker = ProcessInfo.processInfo.environment["GT_CURSOR_IOS_MARKER"] ?? ""

struct ProbeResult: Encodable {
    let axTrusted: Bool
    let appRunning: Bool
    let windowAvailable: Bool
    let markerOccurrences: Int
    let markerSeenAsPromptAndResponse: Bool
    let modelSettingsRecorded: Bool
    let modelSettings: String?
}

func emit(_ result: ProbeResult) {
    let data = try! JSONEncoder().encode(result)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value as? String
}

func children(of element: AXUIElement) -> [AXUIElement] {
    var childrenRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
          let children = childrenRef as? [AXUIElement] else {
        return []
    }
    return children
}

func focusedWindow(of app: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
       let cf = value, CFGetTypeID(cf) == AXUIElementGetTypeID() {
        return (cf as! AXUIElement)
    }
    return nil
}

func firstWindow(of app: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else {
        return nil
    }
    return windows.first
}

func safeModelSettings(from value: String) -> String? {
    let compact = value
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard compact.range(of: "composer", options: .caseInsensitive) != nil else {
        return nil
    }
    guard compact.count <= 80 else {
        return nil
    }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._/-")
    guard compact.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
        return nil
    }
    return compact
}

func countOccurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let range = haystack.range(of: needle, options: [], range: searchRange) {
        count += 1
        searchRange = range.upperBound..<haystack.endIndex
    }
    return count
}

let trusted = AXIsProcessTrusted()
guard trusted else {
    emit(ProbeResult(axTrusted: false, appRunning: false, windowAvailable: false, markerOccurrences: 0, markerSeenAsPromptAndResponse: false, modelSettingsRecorded: false, modelSettings: nil))
    exit(0)
}

guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    emit(ProbeResult(axTrusted: true, appRunning: false, windowAvailable: false, markerOccurrences: 0, markerSeenAsPromptAndResponse: false, modelSettingsRecorded: false, modelSettings: nil))
    exit(0)
}

let app = AXUIElementCreateApplication(running.processIdentifier)
guard let root = focusedWindow(of: app) ?? firstWindow(of: app) else {
    emit(ProbeResult(axTrusted: true, appRunning: true, windowAvailable: false, markerOccurrences: 0, markerSeenAsPromptAndResponse: false, modelSettingsRecorded: false, modelSettings: nil))
    exit(0)
}

var queue: [AXUIElement] = [root]
var visited = 0
var markerOccurrences = 0
var modelSettings: String?
while !queue.isEmpty && visited < 9000 {
    visited += 1
    let element = queue.removeFirst()
    for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
        guard let value = copyString(element, attr), !value.isEmpty else { continue }
        markerOccurrences += countOccurrences(of: marker, in: value)
        if modelSettings == nil {
            modelSettings = safeModelSettings(from: value)
        }
    }
    queue.append(contentsOf: children(of: element))
}

emit(ProbeResult(
    axTrusted: true,
    appRunning: true,
    windowAvailable: true,
    markerOccurrences: markerOccurrences,
    markerSeenAsPromptAndResponse: markerOccurrences >= 2,
    modelSettingsRecorded: modelSettings != nil,
    modelSettings: modelSettings
))
SWIFT

abs_coord() {
  python3 - "$@" <<'PY'
import sys
origin = float(sys.argv[1])
size = float(sys.argv[2])
ratio = float(sys.argv[3])
print(round(origin + size * ratio))
PY
}

tap() {
  local x y
  x="$(abs_coord "$window_x" "$window_w" "$1")"
  y="$(abs_coord "$window_y" "$window_h" "$2")"
  open -a Simulator
  swift "$click_helper" "$x" "$y"
}

type_text() {
  open -a Simulator
  printf '%s' "$1" | xcrun simctl pbcopy "$DEVICE"
  osascript <<'OSA'
tell application "System Events" to key code 9 using command down
OSA
}

press_return() {
  open -a Simulator
  osascript <<'OSA'
tell application "System Events" to key code 36
OSA
}

clear_focused_text() {
  open -a Simulator
  osascript <<'OSA'
tell application "System Events"
  key code 0 using command down
  key code 51
end tell
OSA
}

capture_ocr() {
  local label="$1"
  local stamp screenshot text_file
  stamp="$(date +%Y%m%d-%H%M%S)"
  screenshot="$OUT_DIR/ios-safari-cursor-prompt-$label-$stamp.png"
  text_file="$OUT_DIR/ios-safari-cursor-prompt-$label-$stamp.txt"
  xcrun simctl io "$DEVICE" screenshot "$screenshot" >/dev/null
  swift "$ROOT_DIR/scripts/ocr-image-text.swift" "$screenshot" >"$text_file"
  printf '%s\n%s\n' "$screenshot" "$text_file"
}

capture_screenshot=""
capture_text=""
capture_into() {
  local capture
  capture="$(capture_ocr "$1")"
  capture_screenshot="$(printf '%s\n' "$capture" | sed -n '1p')"
  capture_text="$(printf '%s\n' "$capture" | sed -n '2p')"
}

json_bool() {
  if [[ "$1" == "1" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

run_cursor_probe() {
  GT_CURSOR_IOS_MARKER="$marker" swift "$probe_file"
}

model_settings_is_allowed() {
  python3 - "$1" "$2" <<'PY'
import re
import sys

current = re.sub(r"\s+", " ", sys.argv[1]).strip().lower()
allowed = [
    re.sub(r"\s+", " ", value).strip().lower()
    for value in sys.argv[2].split(",")
    if value.strip()
]
print(1 if current in allowed else 0)
PY
}

verify_allowed_cursor_model_settings() {
  local deadline latest_probe

  if [[ "$REMOTE_APP_ID" == "cursor-agent" ]]; then
    assert_ocr_contains started "$started_text" "Cursor Agent"
    assert_ocr_contains started "$started_text" "Ask mode only|File edits are not enabled"
    assert_ocr_contains started "$started_text" "GPT 5.4 Nano|gpt-5.4-nano-none|gpt-5.4"
    model_settings_preflight_recorded=1
    model_settings_preflight="gpt-5.4-nano-none"
    model_settings_allowed=1
    model_settings_recorded=1
    model_settings="gpt-5.4-nano-none"
    ask_mode_notice_seen=1
    return
  fi

  if [[ "$REQUIRE_ALLOWED_MODEL_SETTINGS" != "0" ]] && [[ -z "${ALLOWED_MODEL_SETTINGS//[[:space:],]/}" ]]; then
    prompt_blocked_before_submit=1
    write_artifact failed "Cursor model/settings preflight has no allowed model settings configured"
    script_completed=1
    echo "Result: failed; Cursor iOS Safari model/settings preflight has no allowed settings configured." >&2
    echo "Artifact: $ARTIFACT_PATH" >&2
    exit 1
  fi

  if [[ "$REQUIRE_ALLOWED_MODEL_SETTINGS" == "0" && -z "${MODEL_SETTINGS_OVERRIDE_REASON//[[:space:]]/}" ]]; then
    prompt_blocked_before_submit=1
    write_artifact failed "Cursor model/settings override requires GT_CURSOR_MODEL_SETTINGS_OVERRIDE_REASON"
    script_completed=1
    echo "Result: failed; Cursor iOS Safari model/settings override requires GT_CURSOR_MODEL_SETTINGS_OVERRIDE_REASON." >&2
    echo "Artifact: $ARTIFACT_PATH" >&2
    exit 1
  fi

  deadline=$((SECONDS + ${GT_CURSOR_IOS_MODEL_PREFLIGHT_WAIT:-15}))
  while (( SECONDS < deadline )); do
    latest_probe="$(run_cursor_probe)"
    cursor_probe_json="$latest_probe"
    cursor_window_available="$(python3 - <<'PY' "$latest_probe"
import json
import sys
payload = json.loads(sys.argv[1])
print(1 if payload.get("windowAvailable") else 0)
PY
)"
    model_settings_preflight_recorded="$(python3 - <<'PY' "$latest_probe"
import json
import sys
payload = json.loads(sys.argv[1])
print(1 if payload.get("modelSettingsRecorded") else 0)
PY
)"
    model_settings_preflight="$(python3 - <<'PY' "$latest_probe"
import json
import sys
payload = json.loads(sys.argv[1])
print(payload.get("modelSettings") or "")
PY
)"
    model_settings_recorded="$model_settings_preflight_recorded"
    model_settings="$model_settings_preflight"
    if [[ "$model_settings_preflight_recorded" == "1" && -n "$model_settings_preflight" ]]; then
      break
    fi
    sleep 1
  done

  if [[ "$model_settings_preflight_recorded" != "1" || -z "$model_settings_preflight" ]]; then
    if [[ "$REQUIRE_ALLOWED_MODEL_SETTINGS" == "0" && "$PREFLIGHT_ONLY" != "1" && -n "${MODEL_SETTINGS_OVERRIDE_REASON//[[:space:]]/}" ]]; then
      model_settings_allowed=1
      model_settings_override_used=1
      return
    fi
    prompt_blocked_before_submit=1
    write_artifact failed "Cursor model/settings preflight failed before prompt submit: visible model/settings could not be read"
    script_completed=1
    echo "Result: failed; Cursor iOS Safari blocked before prompt submit because visible Cursor model/settings could not be read." >&2
    echo "Artifact: $ARTIFACT_PATH" >&2
    exit 1
  fi

  if [[ "$REQUIRE_ALLOWED_MODEL_SETTINGS" == "0" ]]; then
    model_settings_allowed=1
    model_settings_override_used=1
    return
  fi

  model_settings_allowed="$(model_settings_is_allowed "$model_settings_preflight" "$ALLOWED_MODEL_SETTINGS")"
  if [[ "$model_settings_allowed" != "1" ]]; then
    prompt_blocked_before_submit=1
    write_artifact failed "Cursor model/settings preflight blocked prompt submit: visible setting is not in allowed list"
    script_completed=1
    echo "Result: failed; Cursor iOS Safari blocked before prompt submit because visible Cursor model/settings is not allowed." >&2
    echo "Visible model/settings: $model_settings_preflight" >&2
    echo "Allowed model/settings: $ALLOWED_MODEL_SETTINGS" >&2
    echo "Artifact: $ARTIFACT_PATH" >&2
    exit 1
  fi
}

assert_ocr_contains() {
  local label="$1"
  local text_file="$2"
  local pattern="$3"
  if rg -q "$pattern" "$text_file"; then
    return
  fi

  if [[ "$pattern" != *"|"* ]] &&
    python3 - "$text_file" "$pattern" <<'PY'
import re
import sys

path, pattern = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    compact_text = re.sub(r"\s+", "", handle.read())
compact_pattern = re.sub(r"\s+", "", pattern)
sys.exit(0 if compact_pattern in compact_text else 1)
PY
  then
    return
  fi

  echo "Result: failed; OCR for $label did not find expected text: $pattern" >&2
  echo "OCR text: $text_file" >&2
  exit 1
}

assert_backgrounded_away_from_cursor() {
  local label="$1"
  local text_file="$2"

  if [[ ! -s "$text_file" ]]; then
    write_artifact failed "OCR for $label was empty after backgrounding Safari"
    script_completed=1
    echo "Result: failed; OCR for $label was empty after backgrounding Safari." >&2
    echo "Artifact: $ARTIFACT_PATH" >&2
    exit 1
  fi

  if rg -q "Cursor|READY|Ready|Send a prompt|Type a terminal command|Connected|Runs on your Mac|Start Cursor on this Mac|Open Cursor on this Mac" "$text_file"; then
    write_artifact failed "Safari still showed the Cursor workspace after backgrounding"
    script_completed=1
    echo "Result: failed; Safari still showed the Cursor workspace after backgrounding." >&2
    echo "OCR text: $text_file" >&2
    echo "Artifact: $ARTIFACT_PATH" >&2
    exit 1
  fi

  if ! rg -q "Safari|Settings|Search|Wi-Fi|General|Privacy|Apple Account" "$text_file"; then
    write_artifact failed "Backgrounded Simulator state did not expose a recognizable non-Cursor screen"
    script_completed=1
    echo "Result: failed; backgrounded Simulator state did not expose a recognizable non-Cursor screen." >&2
    echo "OCR text: $text_file" >&2
    echo "Artifact: $ARTIFACT_PATH" >&2
    exit 1
  fi
}

run_background_preflight() {
  background_preflight_seen=1
  echo "Backgrounding iOS Safari by launching Settings..."
  if ! xcrun simctl launch "$DEVICE" com.apple.Preferences >/dev/null; then
    write_artifact failed "Could not background Safari by launching iOS Settings"
    script_completed=1
    echo "Result: failed; iOS Simulator Safari background preflight could not launch Settings." >&2
    echo "Artifact: $ARTIFACT_PATH" >&2
    exit 1
  fi
  sleep "${GT_CURSOR_IOS_BACKGROUND_WAIT:-3}"
  capture_into backgrounded
  backgrounded_screenshot="$capture_screenshot"
  backgrounded_text="$capture_text"
  assert_backgrounded_away_from_cursor backgrounded "$backgrounded_text"

  echo "Foregrounding iOS Safari..."
  if ! xcrun simctl launch "$DEVICE" com.apple.mobilesafari >/dev/null; then
    write_artifact failed "Could not foreground iOS Safari after backgrounding"
    script_completed=1
    echo "Result: failed; iOS Simulator Safari background preflight could not relaunch Safari." >&2
    echo "Artifact: $ARTIFACT_PATH" >&2
    exit 1
  fi
  sleep "${GT_CURSOR_IOS_FOREGROUND_WAIT:-5}"
  capture_into foregrounded
  foregrounded_screenshot="$capture_screenshot"
  foregrounded_text="$capture_text"
  assert_ocr_contains foregrounded "$foregrounded_text" "Cursor|READY|Ready|Send a prompt|Type a terminal command"

  if rg -q "OFFLINE|Mac offline|Connection issue" "$foregrounded_text"; then
    write_artifact failed "Cursor workspace was offline after Safari foreground"
    script_completed=1
    echo "Result: failed; iOS Simulator Safari foregrounded to an offline Cursor workspace." >&2
    echo "Artifact: $ARTIFACT_PATH" >&2
    exit 1
  fi
  if cursor_start_card_seen "$foregrounded_text"; then
    write_artifact failed "Cursor returned to the start card after Safari foreground"
    script_completed=1
    echo "Result: failed; iOS Simulator Safari foregrounded to the Cursor start card." >&2
    echo "Artifact: $ARTIFACT_PATH" >&2
    exit 1
  fi

  verify_allowed_cursor_model_settings
  background_recovery_seen=1
  write_artifact passed
  script_completed=1
  echo "Result: passed; iOS Simulator Safari recovered the Cursor surface after background and foreground without prompt submission."
  echo "Model/settings: $model_settings_preflight"
  echo "Prompt sent from Safari: $prompt_sent_from_safari"
  echo "Background screenshot: $backgrounded_screenshot"
  echo "Foreground screenshot: $foregrounded_screenshot"
  echo "Artifact: $ARTIFACT_PATH"
  echo "Device: $DEVICE"
  exit 0
}

url_with_auth_email() {
  python3 - "$1" <<'PY'
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
import sys

url = sys.argv[1]
parts = urlsplit(url)
query = dict(parse_qsl(parts.query, keep_blank_values=True))
query["authProvider"] = "email"
print(urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment)))
PY
}

write_artifact() {
  local result="$1"
  local error_message="${2:-}"
  python3 - "$ARTIFACT_PATH" <<'PY' \
    "$result" \
    "$error_message" \
    "$host_log" \
    "$DEVICE" \
    "$URL" \
    "$REMOTE_APP_ID" \
    "$marker" \
    "$host_device_id" \
    "$host_label" \
    "$(json_bool "$linked_host_started")" \
    "$(json_bool "$link_code_available")" \
    "$(json_bool "$link_state_seen")" \
    "$initial_screenshot" \
    "$initial_text" \
    "$link_screenshot" \
    "$link_text" \
    "$linked_screenshot" \
    "$linked_text" \
    "$started_screenshot" \
    "$started_text" \
    "$typed_screenshot" \
    "$typed_text" \
    "$submitted_screenshot" \
    "$submitted_text" \
    "$cursor_probe_json" \
    "$(json_bool "$typed_marker_seen")" \
    "$(json_bool "$prompt_sent_from_safari")" \
    "$(json_bool "$prompt_blocked_before_submit")" \
    "$(json_bool "$preflight_only_seen")" \
    "$(json_bool "$cursor_window_available")" \
    "$(json_bool "$marker_seen_as_prompt_and_response")" \
    "$(json_bool "$model_settings_preflight_recorded")" \
    "$model_settings_preflight" \
    "$(json_bool "$model_settings_allowed")" \
    "$REQUIRE_ALLOWED_MODEL_SETTINGS" \
    "$ALLOWED_MODEL_SETTINGS" \
    "$MODEL_SETTINGS_OVERRIDE_REASON" \
    "$MODEL_SETTINGS_OVERRIDE_SOURCE" \
    "$(json_bool "$model_settings_override_used")" \
    "$(json_bool "$model_settings_recorded")" \
    "$model_settings" \
    "$(json_bool "$sign_in_screen_seen")" \
    "$(json_bool "$auto_sign_in_attempted")" \
    "$(json_bool "$auto_sign_in_succeeded")" \
    "$sign_in_screenshot" \
    "$sign_in_text" \
    "$signed_in_screenshot" \
    "$signed_in_text" \
    "$(json_bool "$background_preflight_seen")" \
    "$(json_bool "$background_recovery_seen")" \
    "$backgrounded_screenshot" \
    "$backgrounded_text" \
    "$foregrounded_screenshot" \
    "$foregrounded_text" \
    "$(json_bool "$command_surface_marker_seen")" \
    "$(json_bool "$command_surface_done_seen")" \
    "$(json_bool "$ask_mode_notice_seen")"
import json
import sys

(
    path,
    result,
    error_message,
    host_log,
    device,
    url,
    remote_app_id,
    marker,
    host_device_id,
    host_label,
    linked_host_started,
    link_code_available,
    link_state_seen,
    initial_screenshot,
    initial_text,
    link_screenshot,
    link_text,
    linked_screenshot,
    linked_text,
    started_screenshot,
    started_text,
    typed_screenshot,
    typed_text,
    submitted_screenshot,
    submitted_text,
    cursor_probe_json,
    typed_marker_seen,
    prompt_sent_from_safari,
    prompt_blocked_before_submit,
    preflight_only_seen,
    cursor_window_available,
    marker_seen_as_prompt_and_response,
    model_settings_preflight_recorded,
    model_settings_preflight,
    model_settings_allowed,
    require_allowed_model_settings,
    allowed_model_settings,
    model_settings_override_reason,
    model_settings_override_source,
    model_settings_override_used,
    model_settings_recorded,
    model_settings,
    sign_in_screen_seen,
    auto_sign_in_attempted,
    auto_sign_in_succeeded,
    sign_in_screenshot,
    sign_in_text,
    signed_in_screenshot,
    signed_in_text,
    background_preflight_seen,
    background_recovery_seen,
    backgrounded_screenshot,
    backgrounded_text,
    foregrounded_screenshot,
    foregrounded_text,
    command_surface_marker_seen,
    command_surface_done_seen,
    ask_mode_notice_seen,
) = sys.argv[1:]

cursor_probe = None
if cursor_probe_json:
    try:
        cursor_probe = json.loads(cursor_probe_json)
    except json.JSONDecodeError:
        cursor_probe = {"parseError": True}

payload = {
    "result": result,
    "error": error_message or None,
    "hostLog": host_log or None,
    "device": device,
    "url": url,
    "remoteAppId": remote_app_id,
    "marker": marker,
    "hostDeviceId": host_device_id or None,
    "hostLabel": host_label or None,
    "linkedHostStarted": linked_host_started == "true",
    "linkCodeAvailable": link_code_available == "true",
    "linkStateSeen": link_state_seen == "true",
    "typedMarkerSeen": typed_marker_seen == "true",
    "promptSentFromSafari": prompt_sent_from_safari == "true",
    "promptBlockedBeforeSubmit": prompt_blocked_before_submit == "true",
    "preflightOnly": preflight_only_seen == "true",
    "cursorWindowAvailable": cursor_window_available == "true",
    "markerSeenAsPromptAndResponse": marker_seen_as_prompt_and_response == "true",
    "modelSettingsPreflightRecorded": model_settings_preflight_recorded == "true",
    "modelSettingsPreflight": model_settings_preflight or None,
    "modelSettingsAllowed": model_settings_allowed == "true",
    "requireAllowedModelSettings": require_allowed_model_settings != "0",
    "allowedModelSettings": [value.strip() for value in allowed_model_settings.split(",") if value.strip()],
    "modelSettingsOverrideReason": model_settings_override_reason or None,
    "modelSettingsOverrideSource": model_settings_override_source or None,
    "modelSettingsOverrideUsed": model_settings_override_used == "true",
    "modelSettingsRecorded": model_settings_recorded == "true",
    "modelSettings": model_settings or None,
    "signInScreenSeen": sign_in_screen_seen == "true",
    "autoSignInAttempted": auto_sign_in_attempted == "true",
    "autoSignInSucceeded": auto_sign_in_succeeded == "true",
    "backgroundPreflight": background_preflight_seen == "true",
    "backgroundRecoverySeen": background_recovery_seen == "true",
    "commandSurfaceMarkerSeen": command_surface_marker_seen == "true",
    "commandSurfaceDoneSeen": command_surface_done_seen == "true",
    "askModeNoticeSeen": ask_mode_notice_seen == "true",
    "cursorProbe": cursor_probe,
    "screenshots": {
        "initial": initial_screenshot or None,
        "signIn": sign_in_screenshot or None,
        "signedIn": signed_in_screenshot or None,
        "link": link_screenshot or None,
        "linked": linked_screenshot or None,
        "started": started_screenshot or None,
        "typed": typed_screenshot or None,
        "submitted": submitted_screenshot or None,
        "backgrounded": backgrounded_screenshot or None,
        "foregrounded": foregrounded_screenshot or None,
    },
    "ocrTextFiles": {
        "initial": initial_text or None,
        "signIn": sign_in_text or None,
        "signedIn": signed_in_text or None,
        "link": link_text or None,
        "linked": linked_text or None,
        "started": started_text or None,
        "typed": typed_text or None,
        "submitted": submitted_text or None,
        "backgrounded": backgrounded_text or None,
        "foregrounded": foregrounded_text or None,
    },
}

with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

start_x_ratio="${GT_CURSOR_IOS_START_X:-0.5}"
start_y_ratio="${GT_CURSOR_IOS_START_Y:-0.626}"
open_host_x_ratio="${GT_CURSOR_IOS_OPEN_HOST_X:-0.17}"
open_host_y_ratio="${GT_CURSOR_IOS_OPEN_HOST_Y:-0.503}"
email_input_x_ratio="${GT_CURSOR_IOS_EMAIL_X:-0.5}"
email_input_y_ratio="${GT_CURSOR_IOS_EMAIL_Y:-0.665}"
email_continue_x_ratio="${GT_CURSOR_IOS_EMAIL_CONTINUE_X:-0.5}"
email_continue_y_ratio="${GT_CURSOR_IOS_EMAIL_CONTINUE_Y:-0.747}"
password_input_x_ratio="${GT_CURSOR_IOS_PASSWORD_X:-0.5}"
password_input_y_ratio="${GT_CURSOR_IOS_PASSWORD_Y:-0.665}"
signin_x_ratio="${GT_CURSOR_IOS_SIGNIN_X:-0.5}"
signin_y_ratio="${GT_CURSOR_IOS_SIGNIN_Y:-0.747}"
composer_x_ratio="${GT_CURSOR_IOS_COMPOSER_X:-0.452}"
composer_y_ratio="${GT_CURSOR_IOS_COMPOSER_Y:-0.857}"
send_x_ratio="${GT_CURSOR_IOS_SEND_X:-0.895}"
send_y_ratio="${GT_CURSOR_IOS_SEND_Y:-$composer_y_ratio}"

marker="${GT_CURSOR_IOS_MARKER:-GTIOS$(date +%H%M%S)}"
prompt="${GT_CURSOR_IOS_PROMPT:-Reply exactly: $marker}"
linked_host_started=0
link_code_available=0
link_state_seen=0
sign_in_screen_seen=0
auto_sign_in_attempted=0
auto_sign_in_succeeded=0
typed_marker_seen=0
prompt_sent_from_safari=0
prompt_blocked_before_submit=0
preflight_only_seen=0
cursor_window_available=0
marker_seen_as_prompt_and_response=0
model_settings_preflight_recorded=0
model_settings_preflight=""
model_settings_allowed=0
model_settings_override_used=0
model_settings_recorded=0
model_settings=""
cursor_probe_json=""
host_log=""
host_pid=""
host_device_id=""
host_label="${GT_CURSOR_IOS_HOST_LABEL:-Cursor iOS Safari $RUN_STAMP}"
link_code=""
initial_screenshot=""
initial_text=""
sign_in_screenshot=""
sign_in_text=""
signed_in_screenshot=""
signed_in_text=""
link_screenshot=""
link_text=""
linked_screenshot=""
linked_text=""
started_screenshot=""
started_text=""
typed_screenshot=""
typed_text=""
submitted_screenshot=""
submitted_text=""
background_preflight_seen=0
background_recovery_seen=0
backgrounded_screenshot=""
backgrounded_text=""
foregrounded_screenshot=""
foregrounded_text=""
command_surface_marker_seen=0
command_surface_done_seen=0
ask_mode_notice_seen=0
script_completed=0
if [[ "$PREFLIGHT_ONLY" == "1" ]]; then
  preflight_only_seen=1
fi
if [[ "$BACKGROUND_PREFLIGHT_ONLY" == "1" ]]; then
  preflight_only_seen=1
  background_preflight_seen=1
fi

cleanup_host() {
  if [[ -n "$host_pid" ]] && kill -0 "$host_pid" 2>/dev/null; then
    kill "$host_pid" 2>/dev/null || true
    wait "$host_pid" 2>/dev/null || true
  fi
}

start_host_harness() {
  if [[ "$START_HOST_HARNESS" != "1" ]]; then
    return
  fi

  host_log="$(mktemp -t glasstunnel-cursor-ios-host.XXXXXX.log)"
  GLASSTUNNEL_DEV=1 \
  GLASSTUNNEL_KEYCHAIN_SUFFIX="${GT_CURSOR_IOS_KEY_SUFFIX:-cursor-ios-safari-$RUN_STAMP}" \
  GT_TERMINAL_LIVE_HOST_SECONDS="${GT_CURSOR_IOS_HOST_SECONDS:-360}" \
  GT_TERMINAL_LIVE_HOST_LABEL="$host_label" \
  swift run --package-path "$ROOT_DIR/apps/host-macos" TerminalLiveHostHarness >"$host_log" 2>&1 &
  host_pid="$!"
  linked_host_started=1

  local deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$host_pid" 2>/dev/null; then
      echo "Cursor iOS host harness exited before link code." >&2
      sed -E 's/(token|password|secret|key)=([^[:space:]]+)/\1=<redacted>/Ig' "$host_log" >&2 || true
      exit 1
    fi
    host_device_id="$(awk '/^HOST_DEVICE_ID / { print $2; exit }' "$host_log")"
    link_code="$(awk '/^LINK_CODE / { print $2; exit }' "$host_log")"
    if [[ -n "$host_device_id" && -n "$link_code" ]]; then
      link_code_available=1
      return
    fi
    sleep 1
  done

  echo "Timed out waiting for Cursor iOS host link code." >&2
  sed -E 's/(token|password|secret|key)=([^[:space:]]+)/\1=<redacted>/Ig' "$host_log" >&2 || true
  exit 1
}

open_url_with_link_code() {
  local joiner="?"
  if [[ "$URL" == *"?"* ]]; then
    joiner="&"
  fi
  printf '%s%slinkCode=%s' "$URL" "$joiner" "$link_code"
}

on_exit() {
  local status="$?"
  if [[ "$status" -ne 0 && "$script_completed" != "1" && ! -f "$ARTIFACT_PATH" ]]; then
    write_artifact failed "Script exited before completion" || true
  fi
  cleanup_host
  rm -f "$click_helper" "$probe_file"
  exit "$status"
}

trap on_exit EXIT

start_host_harness

workspace_ocr_seen() {
  local text_file="$1"
  rg -q "Connected|Runs on your Mac|Send a prompt|Start Cursor on this Mac|Open Cursor on this Mac|Cursor" "$text_file" &&
    ! rg -q "Your Macs|Mac added|Add another Mac|One-time code|Add this Mac|Open your agents" "$text_file"
}

signin_ocr_seen() {
  local text_file="$1"
  rg -q "Open your agents|Continue with Google|Continue with GitHub|Continue with email|Sign in once" "$text_file"
}

fail_signed_out() {
  local message="$1"
  prompt_blocked_before_submit=1
  write_artifact failed "$message"
  script_completed=1
  echo "Result: failed; $message." >&2
  if [[ "$AUTO_SIGN_IN" != "1" ]]; then
    echo "Simulator Safari auto sign-in is disabled." >&2
  elif [[ -z "${SMOKE_EMAIL//[[:space:]]/}" || -z "${SMOKE_PASSWORD//[[:space:]]/}" ]]; then
    echo "Set SMOKE_EMAIL and SMOKE_PASSWORD in .env.smoke.local, then rerun this smoke." >&2
  else
    echo "Auto sign-in was attempted but the hosted app did not reach the Cursor workspace." >&2
  fi
  echo "Artifact: $ARTIFACT_PATH" >&2
  exit 1
}

auto_sign_in_if_needed() {
  local phase="$1"
  local current_screenshot="$2"
  local current_text="$3"
  local current_url="$4"

  if ! signin_ocr_seen "$current_text"; then
    return 1
  fi

  sign_in_screen_seen=1
  sign_in_screenshot="$current_screenshot"
  sign_in_text="$current_text"

  if [[ "$AUTO_SIGN_IN" != "1" ]]; then
    fail_signed_out "Simulator Safari is signed out during $phase"
  fi

  if [[ -z "${SMOKE_EMAIL//[[:space:]]/}" || -z "${SMOKE_PASSWORD//[[:space:]]/}" ]]; then
    fail_signed_out "Simulator Safari is signed out during $phase and smoke credentials are missing"
  fi

  auto_sign_in_attempted=1
  echo "Simulator Safari is signed out during $phase; attempting email smoke sign-in."
  xcrun simctl openurl "$DEVICE" "$(url_with_auth_email "$current_url")"
  sleep "${GT_CURSOR_IOS_AUTH_WAIT:-3}"

  capture_into sign-in-email
  sign_in_screenshot="$capture_screenshot"
  sign_in_text="$capture_text"

  tap "$email_input_x_ratio" "$email_input_y_ratio"
  type_text "$SMOKE_EMAIL"
  tap "$email_continue_x_ratio" "$email_continue_y_ratio"
  press_return
  sleep "${GT_CURSOR_IOS_AUTH_STEP_WAIT:-2}"

  capture_into sign-in-password
  tap "$password_input_x_ratio" "$password_input_y_ratio"
  type_text "$SMOKE_PASSWORD"
  tap "$signin_x_ratio" "$signin_y_ratio"
  press_return
  sleep "${GT_CURSOR_IOS_AUTH_POST_SUBMIT_SETTLE:-2}"

  local auth_deadline=$((SECONDS + ${GT_CURSOR_IOS_AUTH_SUBMIT_WAIT:-30}))
  while (( SECONDS < auth_deadline )); do
    capture_into signed-in
    signed_in_screenshot="$capture_screenshot"
    signed_in_text="$capture_text"
    if ! signin_ocr_seen "$signed_in_text"; then
      break
    fi
    sleep 2
  done

  if signin_ocr_seen "$signed_in_text"; then
    fail_signed_out "Simulator Safari remained signed out after email smoke sign-in during $phase"
  fi

  xcrun simctl openurl "$DEVICE" "$current_url"
  sleep "${GT_CURSOR_IOS_AUTH_REOPEN_WAIT:-6}"
  capture_into signed-in
  signed_in_screenshot="$capture_screenshot"
  signed_in_text="$capture_text"

  auto_sign_in_succeeded=1
  return 0
}

cursor_start_card_seen() {
  local text_file="$1"
  rg -q "Start Cursor on this Mac|Open Cursor on this Mac|\\bStart\\b|Open on Mac" "$text_file"
}

open_url="$URL"
if [[ "$START_HOST_HARNESS" == "1" && "$FORCE_TEMP_HOST" == "1" && -n "$link_code" ]]; then
  open_url="$(open_url_with_link_code)"
fi

echo "Opening $open_url"
xcrun simctl openurl "$DEVICE" "$open_url"
echo "Waiting ${WAIT_SECONDS}s before interaction..."
sleep "$WAIT_SECONDS"

capture_into initial
initial_screenshot="$capture_screenshot"
initial_text="$capture_text"

if auto_sign_in_if_needed "initial Cursor workspace preflight" "$initial_screenshot" "$initial_text" "$open_url"; then
  initial_screenshot="$signed_in_screenshot"
  initial_text="$signed_in_text"
fi

if [[ "$START_HOST_HARNESS" == "1" && "$FORCE_TEMP_HOST" == "1" ]] &&
  workspace_ocr_seen "$initial_text" &&
  ! rg -q "$host_label" "$initial_text"; then
  echo "Warning: link-code URL opened an existing workspace; continuing against the visible Mac."
fi

if ! workspace_ocr_seen "$initial_text" && rg -q "Your Macs|Mac added|Add this Mac|Enter the code shown on your Mac|ABC123" "$initial_text"; then
  if [[ -z "$link_code" ]]; then
    echo "Result: failed; Safari needs a linked Mac but the smoke has no host link code." >&2
    exit 1
  fi

  if rg -q "Mac added|$host_label" "$initial_text"; then
    link_screenshot="$initial_screenshot"
    link_text="$initial_text"
    link_state_seen=1
  else
    link_url="$(open_url_with_link_code)"
    echo "Safari is on the account host screen; opening a one-time link-code URL for the temporary host."
    xcrun simctl openurl "$DEVICE" "$link_url"
    sleep "$LINK_WAIT_SECONDS"

    for _ in 1 2 3 4 5; do
      capture_into link
      link_screenshot="$capture_screenshot"
      link_text="$capture_text"
      if auto_sign_in_if_needed "Cursor link-code preflight" "$link_screenshot" "$link_text" "$link_url"; then
        link_screenshot="$signed_in_screenshot"
        link_text="$signed_in_text"
      fi
      if rg -q "Mac added|Open|$host_label|Your Macs|Connected|Runs on your Mac|Send a prompt|Cursor" "$link_text"; then
        link_state_seen=1
        break
      fi
      sleep 2
    done
  fi

  assert_ocr_contains link "$link_text" "Mac added|Open|$host_label|Your Macs|Connected|Runs on your Mac|Send a prompt|Cursor"

  if ! workspace_ocr_seen "$link_text"; then
    echo "Opening the linked Mac from the account host list."
    tap "$open_host_x_ratio" "$open_host_y_ratio"
    sleep "$LINK_WAIT_SECONDS"
    xcrun simctl openurl "$DEVICE" "$URL"
    sleep "$WAIT_SECONDS"

    capture_into linked
    linked_screenshot="$capture_screenshot"
    linked_text="$capture_text"
    assert_ocr_contains linked "$linked_text" "Connected|Runs on your Mac|Send a prompt|Start Cursor on this Mac|Open Cursor on this Mac|Cursor"

    initial_screenshot="$linked_screenshot"
    initial_text="$linked_text"
  else
    initial_screenshot="$link_screenshot"
    initial_text="$link_text"
  fi
fi

if ! workspace_ocr_seen "$initial_text"; then
  echo "Result: failed; iOS Simulator Safari did not open a Cursor workspace." >&2
  echo "OCR text: $initial_text" >&2
  exit 1
fi

if cursor_start_card_seen "$initial_text"; then
  tap "$start_x_ratio" "$start_y_ratio"
  sleep "$START_WAIT_SECONDS"
fi

capture_into started
started_screenshot="$capture_screenshot"
started_text="$capture_text"
if cursor_start_card_seen "$started_text"; then
  tap "$start_x_ratio" "$start_y_ratio"
  sleep "$START_WAIT_SECONDS"
  capture_into started
  started_screenshot="$capture_screenshot"
  started_text="$capture_text"
fi
assert_ocr_contains started "$started_text" "Cursor|READY|Ready|Send a prompt|Type a terminal command"
if rg -q "OFFLINE|Mac offline|Connection issue" "$started_text"; then
  write_artifact failed "Temporary Cursor host was offline before prompt submission"
  echo "Result: failed; iOS Simulator Safari opened the temporary Cursor host, but the workspace stayed offline before prompt submission." >&2
  echo "Artifact: $ARTIFACT_PATH" >&2
  if [[ -n "$host_log" ]]; then
    echo "Host log: $host_log" >&2
  fi
  exit 1
fi
if cursor_start_card_seen "$started_text"; then
  write_artifact failed "Cursor stayed on the start card after tapping Start"
  echo "Result: failed; iOS Simulator Safari stayed on the Cursor start card after tapping Start." >&2
  echo "Artifact: $ARTIFACT_PATH" >&2
  exit 1
fi

verify_allowed_cursor_model_settings
if [[ "$BACKGROUND_PREFLIGHT_ONLY" == "1" ]]; then
  run_background_preflight
fi
if [[ "$PREFLIGHT_ONLY" == "1" ]]; then
  preflight_only_seen=1
  write_artifact passed
  script_completed=1
  echo "Result: passed; iOS Simulator Safari opened Cursor and verified model/settings preflight without prompt submission."
  echo "Model/settings: $model_settings_preflight"
  echo "Prompt sent from Safari: $prompt_sent_from_safari"
  echo "Artifact: $ARTIFACT_PATH"
  echo "Device: $DEVICE"
  exit 0
fi

tap "$composer_x_ratio" "$composer_y_ratio"
sleep 0.4
clear_focused_text
sleep 0.2
type_text "$prompt"
sleep 0.8

capture_into typed
typed_screenshot="$capture_screenshot"
typed_text="$capture_text"
assert_ocr_contains typed "$typed_text" "$marker"
typed_marker_seen=1

tap "$send_x_ratio" "$send_y_ratio"
prompt_sent_from_safari=1
sleep "$SUBMITTED_WAIT_SECONDS"

capture_into submitted
submitted_screenshot="$capture_screenshot"
submitted_text="$capture_text"

if [[ "$REMOTE_APP_ID" == "cursor-agent" ]]; then
  deadline=$((SECONDS + RESPONSE_WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    if rg -q "$marker" "$submitted_text"; then
      command_surface_marker_seen=1
    fi
    if rg -q "READY|Ready|prompt returned|Send a prompt" "$submitted_text"; then
      command_surface_done_seen=1
    fi
    if [[ "$command_surface_marker_seen" == "1" && "$command_surface_done_seen" == "1" ]]; then
      break
    fi
    sleep 2
    capture_into submitted
    submitted_screenshot="$capture_screenshot"
    submitted_text="$capture_text"
  done

  if [[ "$command_surface_marker_seen" != "1" || "$command_surface_done_seen" != "1" ]]; then
    write_artifact failed "Cursor Agent command surface did not show marker and recovered ready state"
    echo "Result: failed; iOS Simulator Safari sent the Cursor Agent prompt, but the command surface did not show marker and ready recovery." >&2
    echo "Artifact: $ARTIFACT_PATH" >&2
    exit 1
  fi

  write_artifact passed
  script_completed=1

  echo "Result: passed; iOS Simulator Safari opened Cursor Agent, sent a bounded prompt, and the command surface recovered."
  echo "Marker: $marker"
  echo "Model/settings: $model_settings"
  echo "Typed marker seen: $typed_marker_seen"
  echo "Prompt sent from Safari: $prompt_sent_from_safari"
  echo "Command surface marker seen: $command_surface_marker_seen"
  echo "Command surface done seen: $command_surface_done_seen"
  echo "Artifact: $ARTIFACT_PATH"
  echo "Initial screenshot: $initial_screenshot"
  echo "Started screenshot: $started_screenshot"
  echo "Typed screenshot: $typed_screenshot"
  echo "Submitted screenshot: $submitted_screenshot"
  echo "Device: $DEVICE"
  exit 0
fi

deadline=$((SECONDS + RESPONSE_WAIT_SECONDS))
while (( SECONDS < deadline )); do
  cursor_probe_json="$(run_cursor_probe)"
  cursor_window_available="$(python3 - <<'PY' "$cursor_probe_json"
import json
import sys
payload = json.loads(sys.argv[1])
print(1 if payload.get("windowAvailable") else 0)
PY
)"
  marker_seen_as_prompt_and_response="$(python3 - <<'PY' "$cursor_probe_json"
import json
import sys
payload = json.loads(sys.argv[1])
print(1 if payload.get("markerSeenAsPromptAndResponse") else 0)
PY
)"
  model_settings_recorded="$(python3 - <<'PY' "$cursor_probe_json"
import json
import sys
payload = json.loads(sys.argv[1])
print(1 if payload.get("modelSettingsRecorded") else 0)
PY
)"
  model_settings="$(python3 - <<'PY' "$cursor_probe_json"
import json
import sys
payload = json.loads(sys.argv[1])
print(payload.get("modelSettings") or "")
PY
)"
  if [[ "$marker_seen_as_prompt_and_response" == "1" && "$model_settings_recorded" == "1" ]]; then
    break
  fi
  sleep 1
done

if [[ "$cursor_window_available" != "1" || "$marker_seen_as_prompt_and_response" != "1" || "$model_settings_recorded" != "1" ]]; then
  write_artifact failed "Cursor window probe did not verify prompt, response, and model/settings"
  echo "Result: failed; iOS Simulator Safari sent the prompt, but Cursor probe did not verify prompt, response, and model/settings." >&2
  echo "Cursor probe: $cursor_probe_json" >&2
  echo "Artifact: $ARTIFACT_PATH" >&2
  exit 1
fi

write_artifact passed
script_completed=1

echo "Result: passed; iOS Simulator Safari opened Cursor, sent a bounded prompt, and Cursor showed prompt plus response."
echo "Marker: $marker"
echo "Model/settings: $model_settings"
echo "Typed marker seen: $typed_marker_seen"
echo "Prompt sent from Safari: $prompt_sent_from_safari"
echo "Cursor window available: $cursor_window_available"
echo "Marker seen as prompt and response: $marker_seen_as_prompt_and_response"
echo "Artifact: $ARTIFACT_PATH"
echo "Initial screenshot: $initial_screenshot"
echo "Initial OCR text: $initial_text"
echo "Started screenshot: $started_screenshot"
echo "Started OCR text: $started_text"
echo "Typed screenshot: $typed_screenshot"
echo "Typed OCR text: $typed_text"
echo "Submitted screenshot: $submitted_screenshot"
echo "Submitted OCR text: $submitted_text"
echo "Device: $DEVICE"
