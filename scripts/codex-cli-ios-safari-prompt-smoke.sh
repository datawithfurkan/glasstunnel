#!/usr/bin/env bash
# Verify hosted iOS Simulator Safari can start Codex CLI, send one bounded prompt,
# and request stop through the rendered mobile UI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_CODEX_CLI_IOS_OUT_DIR:-/tmp/glasstunnel-codex-cli-ios-safari}"
APP_URL="${GT_CODEX_CLI_IOS_APP_URL:-https://app.glasstunnel.io}"
URL="${GT_CODEX_CLI_IOS_URL:-$APP_URL/?app=codex-cli&codexCliIosPromptSmoke=$(date +%Y%m%d%H%M%S)}"
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
ARTIFACT_PATH="${GT_CODEX_CLI_IOS_ARTIFACT:-$OUT_DIR/codex-cli-ios-safari-prompt-$RUN_STAMP.json}"
WAIT_SECONDS="${GT_CODEX_CLI_IOS_WAIT:-10}"
START_WAIT_SECONDS="${GT_CODEX_CLI_IOS_START_WAIT:-18}"
PROMPT_WAIT_SECONDS="${GT_CODEX_CLI_IOS_PROMPT_WAIT:-12}"
STOP_WAIT_SECONDS="${GT_CODEX_CLI_IOS_STOP_WAIT:-6}"
DEVICE="${GT_CODEX_CLI_IOS_DEVICE:-${GT_MOBILE_QA_DEVICE:-}}"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:codex-cli:ios-safari-prompt

Opens the hosted Codex CLI view in iOS Simulator Safari, clicks Start when the
stopped recovery card is shown, sends one bounded smoke prompt, clicks Stop, and
OCRs screenshots for each phase.

This is iOS Simulator Safari evidence. It can consume a small amount of Codex
CLI model quota. It requires a visible Simulator window so macOS can deliver
clicks/keystrokes to Safari.

Environment:
  GT_CODEX_CLI_IOS_DEVICE       Simulator UDID. Defaults to GT_MOBILE_QA_DEVICE
                                or the first booted/available iPhone.
  GT_CODEX_CLI_IOS_URL          Full URL to open.
  GT_CODEX_CLI_IOS_WAIT         Seconds to wait before interaction. Default: 10.
  GT_CODEX_CLI_IOS_START_WAIT   Seconds to wait after Start. Default: 18.
  GT_CODEX_CLI_IOS_PROMPT_WAIT  Seconds to wait after sending prompt. Default: 12.
  GT_CODEX_CLI_IOS_STOP_WAIT    Seconds to wait after Stop. Default: 6.
  GT_CODEX_CLI_IOS_PROMPT       Override the prompt sent to Codex CLI.
  GT_CODEX_CLI_IOS_ARTIFACT     JSON artifact path.
  GT_CODEX_CLI_IOS_OUT_DIR      Artifact directory.
  GT_CODEX_CLI_IOS_REQUIRE_MARKER=1
                                Fail unless OCR sees the exact marker in the
                                prompt or stop capture.
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
  screenshot="$OUT_DIR/ios-safari-codex-cli-prompt-$label-$stamp.png"
  text_file="$OUT_DIR/ios-safari-codex-cli-prompt-$label-$stamp.txt"
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
    echo "Result: failed; OCR for $label found unexpected text: $pattern" >&2
    echo "OCR text: $text_file" >&2
    exit 1
  fi
}

json_bool() {
  if [[ "$1" == "1" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

write_artifact() {
  local result="$1"
  local error_message="${2:-}"
  python3 - "$ARTIFACT_PATH" <<'PY' \
    "$result" \
    "$error_message" \
    "$DEVICE" \
    "$URL" \
    "$marker" \
    "$initial_screenshot" \
    "$initial_text" \
    "$started_screenshot" \
    "$started_text" \
    "$prompt_screenshot" \
    "$prompt_text" \
    "$stop_screenshot" \
    "$stop_text" \
    "$(json_bool "$marker_seen")" \
    "$(json_bool "$prompt_state_seen")" \
    "$(json_bool "$stop_state_seen")" \
    "$(json_bool "$strict_marker_required")"
import json
import sys

(
    path,
    result,
    error_message,
    device,
    url,
    marker,
    initial_screenshot,
    initial_text,
    started_screenshot,
    started_text,
    prompt_screenshot,
    prompt_text,
    stop_screenshot,
    stop_text,
    marker_seen,
    prompt_state_seen,
    stop_state_seen,
    strict_marker_required,
) = sys.argv[1:]

payload = {
    "result": result,
    "error": error_message or None,
    "device": device,
    "url": url,
    "marker": marker,
    "markerSeen": marker_seen == "true",
    "promptStateSeen": prompt_state_seen == "true",
    "stopStateSeen": stop_state_seen == "true",
    "strictMarkerRequired": strict_marker_required == "true",
    "screenshots": {
        "initial": initial_screenshot or None,
        "started": started_screenshot or None,
        "prompt": prompt_screenshot or None,
        "stop": stop_screenshot or None,
    },
    "ocrTextFiles": {
        "initial": initial_text or None,
        "started": started_text or None,
        "prompt": prompt_text or None,
        "stop": stop_text or None,
    },
}

with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
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
composer_y_ratio=0.837
send_x_ratio=0.851
send_y_ratio="$composer_y_ratio"

marker="GTIOSCODEX$(date +%s)"
prompt="${GT_CODEX_CLI_IOS_PROMPT:-Reply with exactly $marker, then stop.}"
marker_seen=0
prompt_state_seen=0
stop_state_seen=0
strict_marker_required=0
if [[ "${GT_CODEX_CLI_IOS_REQUIRE_MARKER:-}" == "1" ]]; then
  strict_marker_required=1
fi
initial_screenshot=""
initial_text=""
started_screenshot=""
started_text=""
prompt_screenshot=""
prompt_text=""
stop_screenshot=""
stop_text=""
script_completed=0

on_exit() {
  local status="$?"
  if [[ "$status" -ne 0 && "$script_completed" != "1" ]]; then
    write_artifact failed "Script exited before completion" || true
  fi
  rm -f "$click_helper"
  exit "$status"
}

trap on_exit EXIT

capture_into initial
initial_screenshot="$capture_screenshot"
initial_text="$capture_text"
assert_ocr_contains initial "$initial_text" "Connected|Codex CLI|OpenAI Codex"

if rg -q "Codex CLI stopped|Start Codex CLI on this Mac|\\bStart\\b" "$initial_text"; then
  tap "$start_x_ratio" "$start_y_ratio"
  sleep "$START_WAIT_SECONDS"
fi

capture_into started
started_screenshot="$capture_screenshot"
started_text="$capture_text"
assert_ocr_contains started "$started_text" "Codex CLI|OpenAI Codex|WORKING|READY|RUNNING|Send a prompt|Type a terminal command"
assert_ocr_not_contains started "$started_text" "Codex update prompt|Skip this version|Update now"

tap "$composer_x_ratio" "$composer_y_ratio"
sleep 0.4
type_text "$prompt"
tap "$send_x_ratio" "$send_y_ratio"
sleep "$PROMPT_WAIT_SECONDS"

capture_into prompt
prompt_screenshot="$capture_screenshot"
prompt_text="$capture_text"
assert_ocr_contains prompt "$prompt_text" "$marker|WORKING|RUNNING|Stop response|Stop requested"
if rg -q "$marker" "$prompt_text"; then
  marker_seen=1
fi
if rg -q "WORKING|RUNNING|Stop response|Stop requested" "$prompt_text"; then
  prompt_state_seen=1
fi

tap "$send_x_ratio" "$send_y_ratio"
sleep "$STOP_WAIT_SECONDS"

capture_into stop
stop_screenshot="$capture_screenshot"
stop_text="$capture_text"
assert_ocr_contains stop "$stop_text" "Stop requested|READY|ready|Codex CLI stopped|stopped|interrupt|Interrupted"
if rg -q "$marker" "$stop_text"; then
  marker_seen=1
fi
if rg -q "Stop requested|READY|ready|Codex CLI stopped|stopped|interrupt|Interrupted" "$stop_text"; then
  stop_state_seen=1
fi

if [[ "$strict_marker_required" == "1" && "$marker_seen" != "1" ]]; then
  write_artifact failed "Marker was not visible in prompt or stop OCR capture"
  echo "Result: failed; iOS Simulator Safari requested Stop but OCR did not see the Codex marker." >&2
  echo "Artifact: $ARTIFACT_PATH" >&2
  exit 1
fi

write_artifact passed
script_completed=1

echo "Result: passed; iOS Simulator Safari started Codex CLI, sent a bounded prompt, and requested stop."
echo "Marker: $marker"
echo "Marker seen: $marker_seen"
echo "Prompt state seen: $prompt_state_seen"
echo "Stop state seen: $stop_state_seen"
echo "Artifact: $ARTIFACT_PATH"
echo "Initial screenshot: $initial_screenshot"
echo "Initial OCR text: $initial_text"
echo "Started screenshot: $started_screenshot"
echo "Started OCR text: $started_text"
echo "Prompt screenshot: $prompt_screenshot"
echo "Prompt OCR text: $prompt_text"
echo "Stop screenshot: $stop_screenshot"
echo "Stop OCR text: $stop_text"
echo "Device: $DEVICE"
