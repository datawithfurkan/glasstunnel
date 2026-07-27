#!/usr/bin/env bash
# Verify interrupt/recovery and fresh-session controls through iOS Simulator Safari.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_TERMINAL_IOS_OUT_DIR:-/tmp/glasstunnel-terminal-ios-safari}"
APP_URL="${GT_TERMINAL_IOS_APP_URL:-https://app.glasstunnel.io}"
URL="${GT_TERMINAL_IOS_URL:-$APP_URL/?app=terminal&terminalIosSessionSmoke=$(date +%Y%m%d%H%M%S)}"
WAIT_SECONDS="${GT_TERMINAL_IOS_WAIT:-10}"
DEVICE="${GT_TERMINAL_IOS_DEVICE:-${GT_MOBILE_QA_DEVICE:-}}"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:terminal:ios-safari-session

Opens the hosted Terminal view in iOS Simulator Safari and uses the visible
Simulator window to verify:
  - a long-running command reaches the rendered running state,
  - the Stop control interrupts it,
  - the Terminal accepts a recovery command afterward,
  - New creates an isolated fresh Terminal session,
  - closing the fresh session returns to Default Terminal,
  - closing Default Terminal returns the view to the open-Terminal state.

This is iOS Simulator Safari evidence. It is not physical-phone evidence.

Environment:
  GT_TERMINAL_IOS_DEVICE  Simulator UDID. Defaults to GT_MOBILE_QA_DEVICE
                          or the first booted/available iPhone.
  GT_TERMINAL_IOS_URL     Full URL to open.
  GT_TERMINAL_IOS_WAIT    Seconds to wait before interaction. Default: 10.
  GT_TERMINAL_IOS_OUT_DIR Artifact directory.
USAGE
}

if [[ "${1:-}" == "--" ]]; then
  shift
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

mkdir -p "$OUT_DIR"

if [[ -z "$DEVICE" ]]; then
  DEVICE="$(
    python3 <<'PY'
import json
import subprocess
import sys

def load(args):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", *args, "-j"], text=True)).get("devices", {})

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
open -a Simulator

echo "Opening $URL"
xcrun simctl openurl "$DEVICE" "$URL"
echo "Waiting ${WAIT_SECONDS}s before interaction..."
sleep "$WAIT_SECONDS"

capture_window_diagnostic() {
  local stamp screenshot text_file ax_file
  stamp="$(date +%Y%m%d-%H%M%S)"
  screenshot="$OUT_DIR/ios-safari-terminal-session-window-diagnostic-$stamp.png"
  text_file="$OUT_DIR/ios-safari-terminal-session-window-diagnostic-$stamp.txt"
  ax_file="$OUT_DIR/ios-safari-terminal-session-window-diagnostic-$stamp.ax.txt"

  xcrun simctl io "$DEVICE" screenshot "$screenshot" >/dev/null || true
  if [[ -s "$screenshot" ]]; then
    swift "$ROOT_DIR/scripts/ocr-image-text.swift" "$screenshot" >"$text_file" || true
  fi
  osascript >"$ax_file" <<'OSA' || true
tell application "System Events"
  tell process "Simulator"
    set windowCount to count of windows
    set menuWindowNames to {}
    repeat with itemRef in menu items of menu "Window" of menu bar 1
      set end of menuWindowNames to name of itemRef
    end repeat
    return "visible=" & (visible as text) & linefeed & "windowCount=" & (windowCount as text) & linefeed & "windowMenuItems=" & (menuWindowNames as text)
  end tell
end tell
OSA

  echo "Window diagnostic screenshot: $screenshot" >&2
  echo "Window diagnostic OCR text: $text_file" >&2
  echo "Window diagnostic accessibility text: $ax_file" >&2
}

window_geometry="$(
  osascript <<'OSA'
tell application "System Events"
  tell process "Simulator"
    set p to position of window 1
    set s to size of window 1
    return (item 1 of p as text) & "," & (item 2 of p as text) & "," & (item 1 of s as text) & "," & (item 2 of s as text)
  end tell
end tell
OSA
)" || {
  echo "Result: failed; could not read the Simulator window geometry." >&2
  capture_window_diagnostic
  echo "The simulator framebuffer is reachable, but macOS Accessibility does not expose a Simulator window for tap/type automation." >&2
  echo "Bring the device window fully visible or refresh Accessibility/Automation permissions for the automation host, then rerun." >&2
  exit 1
}

IFS=',' read -r window_x window_y window_w window_h <<<"$window_geometry"

click_helper="$(mktemp -t glasstunnel-ios-click.XXXXXX.swift)"
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
trap 'rm -f "$click_helper"' EXIT

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
  swift "$click_helper" "$x" "$y"
}

type_text() {
  osascript -e "tell application \"System Events\" to keystroke \"$1\""
}

capture_ocr() {
  local label="$1"
  local stamp screenshot text_file
  stamp="$(date +%Y%m%d-%H%M%S)"
  screenshot="$OUT_DIR/ios-safari-terminal-session-$label-$stamp.png"
  text_file="$OUT_DIR/ios-safari-terminal-session-$label-$stamp.txt"
  xcrun simctl io "$DEVICE" screenshot "$screenshot" >/dev/null
  swift "$ROOT_DIR/scripts/ocr-image-text.swift" "$screenshot" >"$text_file"
  printf '%s\n%s\n' "$screenshot" "$text_file"
}

assert_ocr_contains() {
  local label="$1"
  local text_file="$2"
  local pattern="$3"
  if ! rg -q "$pattern" "$text_file"; then
    echo "Result: failed; OCR for $label did not find expected text: $pattern" >&2
    echo "OCR text: $text_file" >&2
    exit 1
  fi
}

assert_ocr_not_contains() {
  local label="$1"
  local text_file="$2"
  local pattern="$3"
  if rg -q "$pattern" "$text_file"; then
    echo "Result: failed; OCR for $label found stale text: $pattern" >&2
    echo "OCR text: $text_file" >&2
    exit 1
  fi
}

capture_screenshot=""
capture_text=""
capture_into() {
  local capture
  capture="$(capture_ocr "$1")"
  capture_screenshot="$(printf '%s\n' "$capture" | sed -n '1p')"
  capture_text="$(printf '%s\n' "$capture" | sed -n '2p')"
}

composer_x_ratio=0.452
composer_y_ratio=0.837
run_x_ratio=0.851
run_y_ratio="$composer_y_ratio"
open_terminal_x_ratio=0.5
open_terminal_y_ratio=0.62
new_x_ratio=0.257
new_y_ratio=0.31
close_x_ratio=0.557
close_y_ratio=0.31

run_marker="GTIOSRUN$(date +%s)"
recovery_marker="GTIOSREC$(date +%s)"
session_marker="GTIOSNEW$(date +%s)"
default_marker="GTIOSDEF$(date +%s)"

capture_into initial
initial_screenshot="$capture_screenshot"
initial_text="$capture_text"
if rg -q "Open Terminal" "$initial_text"; then
  tap "$open_terminal_x_ratio" "$open_terminal_y_ratio"
  sleep 6
  capture_into opened
  opened_screenshot="$capture_screenshot"
  opened_text="$capture_text"
  assert_ocr_contains opened "$opened_text" "Terminal|READY|ready|running|RUNNING"
else
  opened_screenshot="$initial_screenshot"
  opened_text="$initial_text"
fi

tap "$composer_x_ratio" "$composer_y_ratio"
sleep 0.4
type_text "sleep 20"
tap "$run_x_ratio" "$run_y_ratio"
sleep 1.8

capture_into running
running_screenshot="$capture_screenshot"
running_text="$capture_text"
assert_ocr_contains running "$running_text" "RUNNING|running"

tap "$run_x_ratio" "$run_y_ratio"
sleep 2.5

tap "$composer_x_ratio" "$composer_y_ratio"
sleep 0.4
type_text "echo $recovery_marker"
tap "$run_x_ratio" "$run_y_ratio"
sleep 5

capture_into recovery
recovery_screenshot="$capture_screenshot"
recovery_text="$capture_text"
assert_ocr_contains recovery "$recovery_text" "$recovery_marker"

tap "$new_x_ratio" "$new_y_ratio"
sleep 4

capture_into new-session
new_screenshot="$capture_screenshot"
new_text="$capture_text"
assert_ocr_contains new-session "$new_text" "Terminal 2|READY|ready"
assert_ocr_not_contains new-session "$new_text" "$recovery_marker"

tap "$composer_x_ratio" "$composer_y_ratio"
sleep 0.4
type_text "echo $session_marker"
tap "$run_x_ratio" "$run_y_ratio"
sleep 5

capture_into session-output
session_screenshot="$capture_screenshot"
session_text="$capture_text"
assert_ocr_contains session-output "$session_text" "$session_marker"
assert_ocr_not_contains session-output "$session_text" "$recovery_marker"

tap "$close_x_ratio" "$close_y_ratio"
sleep 4

capture_into non-default-closed
non_default_close_screenshot="$capture_screenshot"
non_default_close_text="$capture_text"
assert_ocr_contains non-default-closed "$non_default_close_text" "Default Terminal|READY|ready"
assert_ocr_not_contains non-default-closed "$non_default_close_text" "Terminal 2"

tap "$composer_x_ratio" "$composer_y_ratio"
sleep 0.4
type_text "echo $default_marker"
tap "$run_x_ratio" "$run_y_ratio"
sleep 5

capture_into default-resume
default_resume_screenshot="$capture_screenshot"
default_resume_text="$capture_text"
assert_ocr_contains default-resume "$default_resume_text" "$default_marker"
assert_ocr_not_contains default-resume "$default_resume_text" "$session_marker"

tap "$close_x_ratio" "$close_y_ratio"
sleep 4

capture_into default-closed
default_close_screenshot="$capture_screenshot"
default_close_text="$capture_text"
assert_ocr_contains default-closed "$default_close_text" "Open Terminal|Terminal is ready"

echo "Result: passed; iOS Simulator Safari verified Terminal interrupt, recovery, fresh session isolation, non-default close, default resume, and default close."
echo "Initial screenshot: $initial_screenshot"
echo "Initial OCR text: $initial_text"
echo "Opened screenshot: $opened_screenshot"
echo "Opened OCR text: $opened_text"
echo "Running screenshot: $running_screenshot"
echo "Running OCR text: $running_text"
echo "Recovery marker: $recovery_marker"
echo "Recovery screenshot: $recovery_screenshot"
echo "Recovery OCR text: $recovery_text"
echo "New-session marker: $session_marker"
echo "New-session screenshot: $session_screenshot"
echo "New-session OCR text: $session_text"
echo "Non-default close screenshot: $non_default_close_screenshot"
echo "Non-default close OCR text: $non_default_close_text"
echo "Default resume marker: $default_marker"
echo "Default resume screenshot: $default_resume_screenshot"
echo "Default resume OCR text: $default_resume_text"
echo "Default close screenshot: $default_close_screenshot"
echo "Default close OCR text: $default_close_text"
echo "Device: $DEVICE"
