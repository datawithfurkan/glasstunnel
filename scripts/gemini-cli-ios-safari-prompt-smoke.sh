#!/usr/bin/env bash
# Verify hosted iOS Simulator Safari can start Gemini CLI, submit one bounded
# prompt through the supported command surface, and request stop through the
# rendered mobile UI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_GEMINI_CLI_IOS_OUT_DIR:-/tmp/glasstunnel-gemini-cli-ios-safari}"
APP_URL="${GT_GEMINI_CLI_IOS_APP_URL:-https://app.glasstunnel.io}"
URL="${GT_GEMINI_CLI_IOS_URL:-$APP_URL/?app=gemini-cli&geminiCliIosPromptSmoke=$(date +%Y%m%d%H%M%S)}"
WAIT_SECONDS="${GT_GEMINI_CLI_IOS_WAIT:-10}"
START_WAIT_SECONDS="${GT_GEMINI_CLI_IOS_START_WAIT:-18}"
PROMPT_WAIT_SECONDS="${GT_GEMINI_CLI_IOS_PROMPT_WAIT:-18}"
SUBMITTED_WAIT_SECONDS="${GT_GEMINI_CLI_IOS_SUBMITTED_WAIT:-2}"
STOP_WAIT_SECONDS="${GT_GEMINI_CLI_IOS_STOP_WAIT:-6}"
DEVICE="${GT_GEMINI_CLI_IOS_DEVICE:-${GT_MOBILE_QA_DEVICE:-}}"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:gemini-cli:ios-safari-prompt

Opens the hosted Gemini CLI view in iOS Simulator Safari, clicks Start when the
recovery card is shown, submits one bounded smoke prompt, waits for a
working/stop-capable state or the expected marker, clicks Stop, and OCRs
screenshots for each phase.

This is iOS Simulator Safari evidence. It can consume a small amount of Gemini
CLI provider quota. It requires a visible Simulator window so macOS can deliver
clicks/keystrokes to Safari.

Environment:
  GT_GEMINI_CLI_IOS_DEVICE       Simulator UDID. Defaults to GT_MOBILE_QA_DEVICE
                                 or the first booted/available iPhone.
  GT_GEMINI_CLI_IOS_URL          Full URL to open.
  GT_GEMINI_CLI_IOS_WAIT         Seconds to wait before interaction. Default: 10.
  GT_GEMINI_CLI_IOS_START_WAIT   Seconds to wait after Start. Default: 18.
  GT_GEMINI_CLI_IOS_SUBMITTED_WAIT Seconds to wait after send before local submit
                                   acknowledgement capture. Default: 2.
  GT_GEMINI_CLI_IOS_PROMPT_WAIT  Seconds to wait for working state after send.
                                 Default: 18.
  GT_GEMINI_CLI_IOS_STOP_WAIT    Seconds to wait after Stop. Default: 6.
  GT_GEMINI_CLI_IOS_MARKER       Override the OCR-safe marker. Default: alphanumeric.
  GT_GEMINI_CLI_IOS_PROMPT       Override the prompt sent to Gemini CLI.
  GT_GEMINI_CLI_IOS_OUT_DIR      Artifact directory.
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

window_geometry="$(
  osascript <<'OSA'
tell application "System Events"
  tell process "Simulator"
    if (count of windows) is 0 then error "Simulator has no visible window"
    set p to position of window 1
    set s to size of window 1
    return (item 1 of p as text) & "," & (item 2 of p as text) & "," & (item 1 of s as text) & "," & (item 2 of s as text)
  end tell
end tell
OSA
)" || {
  echo "Result: failed; Simulator is booted but no visible window is available for click/type automation." >&2
  echo "Open the Simulator device window, then rerun this smoke." >&2
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
  screenshot="$OUT_DIR/ios-safari-gemini-cli-prompt-$label-$stamp.png"
  text_file="$OUT_DIR/ios-safari-gemini-cli-prompt-$label-$stamp.txt"
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

capture_screenshot=""
capture_text=""
capture_into() {
  local capture
  capture="$(capture_ocr "$1")"
  capture_screenshot="$(printf '%s\n' "$capture" | sed -n '1p')"
  capture_text="$(printf '%s\n' "$capture" | sed -n '2p')"
}

start_x_ratio=0.5
start_y_ratio=0.626
composer_x_ratio=0.452
composer_y_ratio=0.857
send_x_ratio=0.851
send_y_ratio="$composer_y_ratio"

marker="${GT_GEMINI_CLI_IOS_MARKER:-GTIOSGEMINI$(date +%s)}"
prompt="${GT_GEMINI_CLI_IOS_PROMPT:-Reply first with exactly $marker on its own line, then keep writing harmless filler text until stopped.}"

capture_into initial
initial_screenshot="$capture_screenshot"
initial_text="$capture_text"
assert_ocr_contains initial "$initial_text" "Connected|Gemini CLI"

if rg -q "Gemini CLI stopped|Gemini CLI is ready|Start Gemini CLI on this Mac|\\bStart\\b" "$initial_text"; then
  tap "$start_x_ratio" "$start_y_ratio"
  sleep "$START_WAIT_SECONDS"
fi

capture_into started
started_screenshot="$capture_screenshot"
started_text="$capture_text"
assert_ocr_contains started "$started_text" "Gemini CLI|WORKING|READY|RUNNING|Send a prompt|Type a terminal command|provider/model"

tap "$composer_x_ratio" "$composer_y_ratio"
sleep 0.4
type_text "$prompt"
sleep 0.8

capture_into typed
typed_screenshot="$capture_screenshot"
typed_text="$capture_text"
assert_ocr_contains typed "$typed_text" "$marker"

tap "$send_x_ratio" "$send_y_ratio"
sleep "$SUBMITTED_WAIT_SECONDS"

capture_into submitted
submitted_screenshot="$capture_screenshot"
submitted_text="$capture_text"
if ! rg -q "$marker|user input submitted|WORKING|RUNNING|Stop response|Stop requested" "$submitted_text"; then
  if rg -q "Type your message or @path/to/file|Shift\\+Tab to accept edits" "$submitted_text"; then
    echo "Result: failed; Safari is showing Gemini's interactive TUI after send instead of the supported headless prompt state." >&2
    echo "This usually means the local Mac app is still holding an older Gemini interactive session or is not running the current Gemini adapter." >&2
    echo "OCR text: $submitted_text" >&2
    exit 1
  fi
  assert_ocr_contains submitted "$submitted_text" "$marker|user input submitted|WORKING|RUNNING|Stop response|Stop requested"
fi

if rg -q "$marker|WORKING|RUNNING|Stop response|Stop requested|Thinking" "$submitted_text"; then
  prompt_screenshot="$submitted_screenshot"
  prompt_text="$submitted_text"
else
  sleep "$PROMPT_WAIT_SECONDS"

  capture_into prompt
  prompt_screenshot="$capture_screenshot"
  prompt_text="$capture_text"
  assert_ocr_contains prompt "$prompt_text" "$marker|WORKING|RUNNING|Stop response|Stop requested|Thinking"
fi

tap "$send_x_ratio" "$send_y_ratio"
sleep "$STOP_WAIT_SECONDS"

capture_into stop
stop_screenshot="$capture_screenshot"
stop_text="$capture_text"
assert_ocr_contains stop "$stop_text" "Stop requested|READY|ready|Gemini CLI is ready|stopped|interrupt|Interrupted|prompt returned"

echo "Result: passed; iOS Simulator Safari started Gemini CLI, sent a bounded prompt, and requested stop."
echo "Marker: $marker"
echo "Initial screenshot: $initial_screenshot"
echo "Initial OCR text: $initial_text"
echo "Started screenshot: $started_screenshot"
echo "Started OCR text: $started_text"
echo "Typed screenshot: $typed_screenshot"
echo "Typed OCR text: $typed_text"
echo "Submitted screenshot: $submitted_screenshot"
echo "Submitted OCR text: $submitted_text"
echo "Prompt screenshot: $prompt_screenshot"
echo "Prompt OCR text: $prompt_text"
echo "Stop screenshot: $stop_screenshot"
echo "Stop OCR text: $stop_text"
echo "Device: $DEVICE"
