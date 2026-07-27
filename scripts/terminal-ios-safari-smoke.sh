#!/usr/bin/env bash
# Verify the hosted Terminal surface renders in iOS Simulator Safari and catch
# known Terminal.app continuity regressions that are visible only in Safari.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_TERMINAL_IOS_OUT_DIR:-/tmp/glasstunnel-terminal-ios-safari}"
APP_URL="${GT_TERMINAL_IOS_APP_URL:-https://app.glasstunnel.io}"
URL="${GT_TERMINAL_IOS_URL:-$APP_URL/?app=terminal&terminalIosSmoke=$(date +%Y%m%d%H%M%S)}"
WAIT_SECONDS="${GT_TERMINAL_IOS_WAIT:-10}"
DEVICE="${GT_TERMINAL_IOS_DEVICE:-${GT_MOBILE_QA_DEVICE:-}}"
TEXT_FILE=""

usage() {
  cat <<'USAGE'
Usage: pnpm qa:terminal:ios-safari

Opens the hosted Terminal view in iOS Simulator Safari, captures a screenshot,
extracts visible text with macOS Vision OCR, and verifies that the Terminal
surface is visible without the known ambiguous `screen` attach text.

This is rendered iOS Simulator Safari evidence only. It does not prove command
delivery, interrupt behavior, or physical-phone behavior.

Environment:
  GT_TERMINAL_IOS_DEVICE   Simulator UDID. Defaults to GT_MOBILE_QA_DEVICE or
                           the first booted/available iPhone.
  GT_TERMINAL_IOS_URL      Full URL to open.
  GT_TERMINAL_IOS_WAIT     Seconds to wait before screenshot. Default: 10.
  GT_TERMINAL_IOS_OUT_DIR  Artifact directory.
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
echo "Waiting ${WAIT_SECONDS}s before screenshot..."
sleep "$WAIT_SECONDS"

stamp="$(date +%Y%m%d-%H%M%S)"
screenshot="$OUT_DIR/ios-safari-terminal-$stamp.png"
TEXT_FILE="$OUT_DIR/ios-safari-terminal-$stamp.txt"

xcrun simctl io "$DEVICE" screenshot "$screenshot" >/dev/null
swift "$ROOT_DIR/scripts/ocr-image-text.swift" "$screenshot" >"$TEXT_FILE"

text="$(tr '\n' ' ' <"$TEXT_FILE")"
lower_text="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"

if [[ "$lower_text" != *"terminal"* ]]; then
  echo "Result: failed; OCR did not find Terminal text." >&2
  echo "Screenshot: $screenshot" >&2
  echo "OCR text: $TEXT_FILE" >&2
  exit 1
fi

if [[ "$lower_text" != *"type a terminal command"* && "$lower_text" != *"default terminal"* && "$lower_text" != *"open terminal"* ]]; then
  echo "Result: failed; OCR did not find the Terminal command surface." >&2
  echo "Screenshot: $screenshot" >&2
  echo "OCR text: $TEXT_FILE" >&2
  exit 1
fi

if [[ "$lower_text" == *"several suitable screens"* || "$lower_text" == *"glasstunnel-terminal-two"* ]]; then
  echo "Result: failed; Safari still shows ambiguous screen-session output." >&2
  echo "Screenshot: $screenshot" >&2
  echo "OCR text: $TEXT_FILE" >&2
  exit 1
fi

echo "Result: passed; iOS Simulator Safari rendered the Terminal surface without ambiguous screen-session text."
echo "Screenshot: $screenshot"
echo "OCR text: $TEXT_FILE"
echo "Device: $DEVICE"
