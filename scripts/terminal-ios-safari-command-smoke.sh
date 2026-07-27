#!/usr/bin/env bash
# Verify command delivery through the hosted Terminal surface in iOS Simulator Safari.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_TERMINAL_IOS_OUT_DIR:-/tmp/glasstunnel-terminal-ios-safari}"
APP_URL="${GT_TERMINAL_IOS_APP_URL:-https://app.glasstunnel.io}"
URL="${GT_TERMINAL_IOS_URL:-$APP_URL/?app=terminal&terminalIosCommandSmoke=$(date +%Y%m%d%H%M%S)}"
WAIT_SECONDS="${GT_TERMINAL_IOS_WAIT:-10}"
COMMAND_WAIT_SECONDS="${GT_TERMINAL_IOS_COMMAND_WAIT:-6}"
DEVICE="${GT_TERMINAL_IOS_DEVICE:-${GT_MOBILE_QA_DEVICE:-}}"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:terminal:ios-safari-command

Opens the hosted Terminal view in iOS Simulator Safari, focuses the rendered
Terminal composer through the visible Simulator window, sends a benign echo
command, captures a screenshot, OCRs it, and verifies the echoed marker appears.

This is iOS Simulator Safari command-delivery evidence. It is not physical-phone
evidence and does not prove long-running interrupt or full session controls.

Environment:
  GT_TERMINAL_IOS_DEVICE        Simulator UDID. Defaults to GT_MOBILE_QA_DEVICE
                                or the first booted/available iPhone.
  GT_TERMINAL_IOS_URL           Full URL to open.
  GT_TERMINAL_IOS_WAIT          Seconds to wait before interaction. Default: 10.
  GT_TERMINAL_IOS_COMMAND_WAIT  Seconds to wait after sending command. Default: 6.
  GT_TERMINAL_IOS_OUT_DIR       Artifact directory.
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
    set p to position of window 1
    set s to size of window 1
    return (item 1 of p as text) & "," & (item 2 of p as text) & "," & (item 1 of s as text) & "," & (item 2 of s as text)
  end tell
end tell
OSA
)" || {
  echo "Result: failed; could not read the Simulator window geometry." >&2
  echo "Grant Accessibility access for the automation host, then rerun." >&2
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

composer_x="$(abs_coord "$window_x" "$window_w" 0.452)"
composer_y="$(abs_coord "$window_y" "$window_h" 0.837)"
run_x="$(abs_coord "$window_x" "$window_w" 0.851)"
run_y="$composer_y"

marker="GTIOSSAFARI$(date +%s)"
command="echo $marker"

swift "$click_helper" "$composer_x" "$composer_y"
sleep 0.5
osascript -e "tell application \"System Events\" to keystroke \"$command\""
swift "$click_helper" "$run_x" "$run_y"

echo "Waiting ${COMMAND_WAIT_SECONDS}s for command output..."
sleep "$COMMAND_WAIT_SECONDS"

stamp="$(date +%Y%m%d-%H%M%S)"
screenshot="$OUT_DIR/ios-safari-terminal-command-$stamp.png"
text_file="$OUT_DIR/ios-safari-terminal-command-$stamp.txt"

xcrun simctl io "$DEVICE" screenshot "$screenshot" >/dev/null
swift "$ROOT_DIR/scripts/ocr-image-text.swift" "$screenshot" >"$text_file"

if ! rg -q "$marker" "$text_file"; then
  echo "Result: failed; OCR did not find the Terminal command marker." >&2
  echo "Marker: $marker" >&2
  echo "Screenshot: $screenshot" >&2
  echo "OCR text: $text_file" >&2
  exit 1
fi

echo "Result: passed; iOS Simulator Safari delivered a Terminal command and rendered output."
echo "Marker: $marker"
echo "Screenshot: $screenshot"
echo "OCR text: $text_file"
echo "Device: $DEVICE"
