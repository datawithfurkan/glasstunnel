#!/usr/bin/env bash
# Verify hosted iOS Simulator Safari shows an actionable Codex CLI recovery state.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_CODEX_CLI_IOS_OUT_DIR:-/tmp/glasstunnel-codex-cli-ios-safari}"
APP_URL="${GT_CODEX_CLI_IOS_APP_URL:-https://app.glasstunnel.io}"
URL="${GT_CODEX_CLI_IOS_URL:-$APP_URL/?app=codex-cli&codexCliIosRecoverySmoke=$(date +%Y%m%d%H%M%S)}"
WAIT_SECONDS="${GT_CODEX_CLI_IOS_WAIT:-10}"
DEVICE="${GT_CODEX_CLI_IOS_DEVICE:-${GT_MOBILE_QA_DEVICE:-}}"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:codex-cli:ios-safari-recovery

Opens the hosted Codex CLI view in iOS Simulator Safari, captures a screenshot,
OCRs it, and verifies a stopped/exited Codex CLI session renders a clear Start
recovery action for the linked Mac.

This is hosted iOS Simulator Safari evidence. It does not start a live Codex
agent session, send a prompt, consume model quota, or prove interrupt/runtime
controls.

Environment:
  GT_CODEX_CLI_IOS_DEVICE   Simulator UDID. Defaults to GT_MOBILE_QA_DEVICE
                            or the first booted/available iPhone.
  GT_CODEX_CLI_IOS_URL      Full URL to open.
  GT_CODEX_CLI_IOS_WAIT     Seconds to wait before capture. Default: 10.
  GT_CODEX_CLI_IOS_OUT_DIR  Artifact directory.
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
echo "Waiting ${WAIT_SECONDS}s before capture..."
sleep "$WAIT_SECONDS"

stamp="$(date +%Y%m%d-%H%M%S)"
screenshot="$OUT_DIR/ios-safari-codex-cli-recovery-$stamp.png"
text_file="$OUT_DIR/ios-safari-codex-cli-recovery-$stamp.txt"

xcrun simctl io "$DEVICE" screenshot "$screenshot" >/dev/null
swift "$ROOT_DIR/scripts/ocr-image-text.swift" "$screenshot" >"$text_file"

require_text() {
  local pattern="$1"
  local message="$2"
  if ! rg -q "$pattern" "$text_file"; then
    echo "Result: failed; $message" >&2
    echo "Screenshot: $screenshot" >&2
    echo "OCR text: $text_file" >&2
    exit 1
  fi
}

reject_text() {
  local pattern="$1"
  local message="$2"
  if rg -q "$pattern" "$text_file"; then
    echo "Result: failed; $message" >&2
    echo "Screenshot: $screenshot" >&2
    echo "OCR text: $text_file" >&2
    exit 1
  fi
}

require_text "Connected" "hosted Codex CLI view did not show the linked Mac as connected."
require_text "Codex CLI stopped" "hosted Codex CLI view did not show the stopped recovery title."
require_text "Start Codex CLI on this Mac" "hosted Codex CLI view did not show recovery copy."
require_text "\\bStart\\b" "hosted Codex CLI view did not show a Start action."
reject_text "Type a terminal command|offline|Preparing" "hosted Codex CLI recovery exposed stale input or unavailable copy."

echo "Result: passed; iOS Simulator Safari shows actionable Codex CLI recovery."
echo "Screenshot: $screenshot"
echo "OCR text: $text_file"
echo "Device: $DEVICE"
