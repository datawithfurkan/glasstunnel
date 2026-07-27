#!/usr/bin/env bash
# Verify hosted iOS Simulator Safari can start OpenCode, submit one bounded
# prompt, observe a working/stop-capable state, and request stop through the
# rendered mobile UI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_OPENCODE_IOS_OUT_DIR:-/tmp/glasstunnel-opencode-ios-safari}"
APP_URL="${GT_OPENCODE_IOS_APP_URL:-https://app.glasstunnel.io}"
URL="${GT_OPENCODE_IOS_URL:-$APP_URL/?app=opencode&opencodeIosPromptSmoke=$(date +%Y%m%d%H%M%S)}"
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
ARTIFACT_PATH="${GT_OPENCODE_IOS_ARTIFACT:-$OUT_DIR/opencode-ios-safari-prompt-$RUN_STAMP.json}"
WAIT_SECONDS="${GT_OPENCODE_IOS_WAIT:-10}"
START_WAIT_SECONDS="${GT_OPENCODE_IOS_START_WAIT:-18}"
PROMPT_WAIT_SECONDS="${GT_OPENCODE_IOS_PROMPT_WAIT:-18}"
SUBMITTED_WAIT_SECONDS="${GT_OPENCODE_IOS_SUBMITTED_WAIT:-2}"
STOP_WAIT_SECONDS="${GT_OPENCODE_IOS_STOP_WAIT:-6}"
LINK_WAIT_SECONDS="${GT_OPENCODE_IOS_LINK_WAIT:-10}"
SESSION_SWITCH="${GT_OPENCODE_IOS_SESSION_SWITCH:-0}"
RUNTIME_MODEL="${GT_OPENCODE_IOS_MODEL:-opencode/deepseek-v4-flash-free}"
DEVICE="${GT_OPENCODE_IOS_DEVICE:-${GT_MOBILE_QA_DEVICE:-}}"
START_HOST_HARNESS="${GT_OPENCODE_IOS_START_HOST:-1}"
FORCE_TEMP_HOST="${GT_OPENCODE_IOS_FORCE_TEMP_HOST:-1}"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:opencode:ios-safari-prompt

Opens the hosted OpenCode view in iOS Simulator Safari, clicks Start when the
recovery card is shown, submits one bounded smoke prompt, waits for a
working/stop-capable state, clicks Stop, and OCRs screenshots for each phase.

This is iOS Simulator Safari evidence. It can consume a small amount of model
quota from the locally configured OpenCode provider. It requires a visible
Simulator window so macOS can deliver clicks/keystrokes to Safari.

Environment:
  GT_OPENCODE_IOS_DEVICE       Simulator UDID. Defaults to GT_MOBILE_QA_DEVICE
                               or the first booted/available iPhone.
  GT_OPENCODE_IOS_URL          Full URL to open.
  GT_OPENCODE_IOS_WAIT         Seconds to wait before interaction. Default: 10.
  GT_OPENCODE_IOS_START_WAIT   Seconds to wait after Start. Default: 18.
  GT_OPENCODE_IOS_SUBMITTED_WAIT Seconds to wait after send before local submit
                                 acknowledgement capture. Default: 2.
  GT_OPENCODE_IOS_PROMPT_WAIT  Seconds to wait for working state after send.
                               Default: 18.
  GT_OPENCODE_IOS_STOP_WAIT    Seconds to wait after Stop. Default: 6.
  GT_OPENCODE_IOS_LINK_WAIT    Seconds to wait after Add Mac/Open. Default: 10.
  GT_OPENCODE_IOS_MARKER       Override the OCR-safe marker. Default: numeric.
  GT_OPENCODE_IOS_PROMPT       Override the prompt sent to OpenCode.
  GT_OPENCODE_IOS_ARTIFACT     JSON artifact path.
  GT_OPENCODE_IOS_OUT_DIR      Artifact directory.
  GT_OPENCODE_IOS_START_HOST=0 Do not start a temporary local host harness.
                               Use only when Safari already has a linked Mac.
  GT_OPENCODE_IOS_FORCE_TEMP_HOST=0
                               Do not navigate from an existing workspace to
                               the temporary host. Default: 1 when the harness
                               is enabled.
  GT_OPENCODE_IOS_OPEN_HOST_X/Y Override click ratios for the first host Open
                               button after an automatic link-code claim.
  GT_OPENCODE_IOS_SEND_X/Y      Override click ratios for the Send/Stop button.
  GT_OPENCODE_IOS_REQUIRE_MARKER=1
                               Fail unless OCR sees the exact marker after
                               prompt submission.
  GT_OPENCODE_IOS_SESSION_SWITCH=1
                               Seed two real OpenCode sessions and verify
                               switching to the non-default session in Safari.
  GT_OPENCODE_IOS_SESSION_SWITCH_X/Y
                               Override click ratios for the non-default
                               session target tile.
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

write_preflight_artifact() {
  local result="$1"
  local error_message="$2"
  local phase="$3"
  python3 - "$ARTIFACT_PATH" <<'PY' \
    "$result" \
    "$error_message" \
    "$phase" \
    "$DEVICE" \
    "${state:-unknown}" \
    "$URL" \
    "$SESSION_SWITCH" \
    "$START_HOST_HARNESS" \
    "$FORCE_TEMP_HOST"
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
    session_switch,
    start_host_harness,
    force_temp_host,
) = sys.argv[1:]

payload = {
    "result": result,
    "error": error_message or None,
    "phase": phase,
    "device": device or None,
    "deviceState": device_state or None,
    "url": url,
    "sessionSwitch": session_switch == "1",
    "startHostHarness": start_host_harness == "1",
    "forceTempHost": force_temp_host == "1",
    "createdAt": datetime.now(timezone.utc).isoformat(),
}

with open(artifact_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

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
  screenshot="$OUT_DIR/ios-safari-opencode-prompt-$label-$stamp.png"
  text_file="$OUT_DIR/ios-safari-opencode-prompt-$label-$stamp.txt"
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
    "$host_log" \
    "$DEVICE" \
    "$URL" \
    "$marker" \
    "$(json_bool "$linked_host_started")" \
    "$(json_bool "$link_code_available")" \
    "$(json_bool "$link_state_seen")" \
    "$host_device_id" \
    "$host_label" \
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
    "$prompt_screenshot" \
    "$prompt_text" \
    "$stop_screenshot" \
    "$stop_text" \
    "$(json_bool "$marker_seen")" \
    "$(json_bool "$typedMarkerSeen")" \
    "$(json_bool "$submittedMarkerSeen")" \
    "$(json_bool "$promptStateSeen")" \
    "$(json_bool "$stopStateSeen")" \
    "$(json_bool "$strict_marker_required")" \
    "$(json_bool "$session_switch_enabled")" \
    "$session_default_label" \
    "$session_switch_label" \
    "$session_default_marker" \
    "$session_switch_marker" \
    "$session_before_screenshot" \
    "$session_before_text" \
    "$session_after_screenshot" \
    "$session_after_text" \
    "$(json_bool "$sessionTargetsVisible")" \
    "$(json_bool "$sessionSwitchRequested")" \
    "$(json_bool "$sessionSwitchHistoryVisible")"
import json
import sys

(
    path,
    result,
    error_message,
    host_log,
    device,
    url,
    marker,
    linked_host_started,
    link_code_available,
    link_state_seen,
    host_device_id,
    host_label,
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
    prompt_screenshot,
    prompt_text,
    stop_screenshot,
    stop_text,
    marker_seen,
    typed_marker_seen,
    submitted_marker_seen,
    prompt_state_seen,
    stop_state_seen,
    strict_marker_required,
    session_switch_enabled,
    session_default_label,
    session_switch_label,
    session_default_marker,
    session_switch_marker,
    session_before_screenshot,
    session_before_text,
    session_after_screenshot,
    session_after_text,
    session_targets_visible,
    session_switch_requested,
    session_switch_history_visible,
) = sys.argv[1:]

payload = {
    "result": result,
    "error": error_message or None,
    "hostLog": host_log or None,
    "device": device,
    "url": url,
    "marker": marker,
    "linkedHostStarted": linked_host_started == "true",
    "linkCodeAvailable": link_code_available == "true",
    "linkStateSeen": link_state_seen == "true",
    "hostDeviceId": host_device_id or None,
    "hostLabel": host_label or None,
    "markerSeen": marker_seen == "true",
    "typedMarkerSeen": typed_marker_seen == "true",
    "submittedMarkerSeen": submitted_marker_seen == "true",
    "promptStateSeen": prompt_state_seen == "true",
    "stopStateSeen": stop_state_seen == "true",
    "strictMarkerRequired": strict_marker_required == "true",
    "sessionSwitchEnabled": session_switch_enabled == "true",
    "sessionDefaultLabel": session_default_label or None,
    "sessionSwitchLabel": session_switch_label or None,
    "sessionDefaultMarker": session_default_marker or None,
    "sessionSwitchMarker": session_switch_marker or None,
    "sessionTargetsVisible": session_targets_visible == "true",
    "sessionSwitchRequested": session_switch_requested == "true",
    "sessionSwitchHistoryVisible": session_switch_history_visible == "true",
    "screenshots": {
        "initial": initial_screenshot or None,
        "link": link_screenshot or None,
        "linked": linked_screenshot or None,
        "started": started_screenshot or None,
        "typed": typed_screenshot or None,
        "submitted": submitted_screenshot or None,
        "prompt": prompt_screenshot or None,
        "stop": stop_screenshot or None,
        "sessionBefore": session_before_screenshot or None,
        "sessionAfter": session_after_screenshot or None,
    },
    "ocrTextFiles": {
        "initial": initial_text or None,
        "link": link_text or None,
        "linked": linked_text or None,
        "started": started_text or None,
        "typed": typed_text or None,
        "submitted": submitted_text or None,
        "prompt": prompt_text or None,
        "stop": stop_text or None,
        "sessionBefore": session_before_text or None,
        "sessionAfter": session_after_text or None,
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
open_host_x_ratio="${GT_OPENCODE_IOS_OPEN_HOST_X:-0.84}"
open_host_y_ratio="${GT_OPENCODE_IOS_OPEN_HOST_Y:-0.47}"
composer_x_ratio=0.452
composer_y_ratio=0.857
send_x_ratio="${GT_OPENCODE_IOS_SEND_X:-0.895}"
send_y_ratio="${GT_OPENCODE_IOS_SEND_Y:-$composer_y_ratio}"
session_switch_x_ratio="${GT_OPENCODE_IOS_SESSION_SWITCH_X:-0.72}"
session_switch_y_ratio="${GT_OPENCODE_IOS_SESSION_SWITCH_Y:-0.30}"

marker="${GT_OPENCODE_IOS_MARKER:-178163$(date +%s)}"
prompt="${GT_OPENCODE_IOS_PROMPT:-Reply first with exactly $marker on its own line, then keep writing harmless filler text until stopped.}"
session_switch_enabled=0
if [[ "$SESSION_SWITCH" == "1" ]]; then
  session_switch_enabled=1
fi
marker_seen=0
typedMarkerSeen=0
submittedMarkerSeen=0
promptStateSeen=0
stopStateSeen=0
sessionTargetsVisible=0
sessionSwitchRequested=0
sessionSwitchHistoryVisible=0
linked_host_started=0
link_code_available=0
link_state_seen=0
strict_marker_required=0
if [[ "${GT_OPENCODE_IOS_REQUIRE_MARKER:-}" == "1" ]]; then
  strict_marker_required=1
fi
host_log=""
host_pid=""
host_device_id=""
host_label="${GT_OPENCODE_IOS_HOST_LABEL:-OpenCode iOS Safari $RUN_STAMP}"
link_code=""
opencode_data_home=""
seed_default_dir=""
seed_switch_dir=""
session_default_label=""
session_switch_label=""
session_default_marker="${GT_OPENCODE_IOS_SESSION_DEFAULT_MARKER:-178165$(date +%s)}"
session_switch_marker="${GT_OPENCODE_IOS_SESSION_SWITCH_MARKER:-178164$(date +%s)}"
session_before_screenshot=""
session_before_text=""
session_after_screenshot=""
session_after_text=""
initial_screenshot=""
initial_text=""
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
prompt_screenshot=""
prompt_text=""
stop_screenshot=""
stop_text=""
script_completed=0

cleanup_host() {
  if [[ -n "$host_pid" ]] && kill -0 "$host_pid" 2>/dev/null; then
    kill "$host_pid" 2>/dev/null || true
    wait "$host_pid" 2>/dev/null || true
  fi
  if [[ -n "$opencode_data_home" ]]; then
    if [[ "$script_completed" == "1" || "${GT_OPENCODE_IOS_KEEP_DATA_ON_FAILURE:-1}" != "1" ]]; then
      rm -rf "$opencode_data_home"
    else
      echo "Preserved OpenCode iOS smoke data home after failure: $opencode_data_home" >&2
    fi
  fi
  [[ -n "$seed_default_dir" ]] && rm -rf "$seed_default_dir"
  [[ -n "$seed_switch_dir" ]] && rm -rf "$seed_switch_dir"
}

start_host_harness() {
  if [[ "$START_HOST_HARNESS" != "1" ]]; then
    return
  fi

  host_log="$(mktemp -t glasstunnel-opencode-ios-host.XXXXXX.log)"
  opencode_data_home="$(mktemp -d -t glasstunnel-opencode-ios-data.XXXXXX)"

  if [[ "$session_switch_enabled" == "1" ]]; then
    opencode_bin="${GT_OPENCODE_BIN:-$(command -v opencode || true)}"
    if [[ -z "$opencode_bin" ]]; then
      echo "OpenCode CLI not found. Cannot seed iOS session-switch smoke data." >&2
      exit 1
    fi
    seed_default_dir="$(mktemp -d -t gt-opencode-ios-default.XXXXXX)"
    seed_switch_dir="$(mktemp -d -t gt-opencode-ios-switch.XXXXXX)"
    session_default_label="$(basename "$seed_default_dir")"
    session_switch_label="$(basename "$seed_switch_dir")"
    (
      cd "$seed_switch_dir"
      XDG_DATA_HOME="$opencode_data_home" \
        "$opencode_bin" run --model "$RUNTIME_MODEL" \
          "Do not use tools. Reply with exactly ${session_switch_marker}."
    ) >"$OUT_DIR/opencode-ios-session-switch-seed-$RUN_STAMP.txt" 2>&1
    (
      cd "$seed_default_dir"
      XDG_DATA_HOME="$opencode_data_home" \
        "$opencode_bin" run --model "$RUNTIME_MODEL" \
          "Do not use tools. Reply with exactly ${session_default_marker}."
    ) >"$OUT_DIR/opencode-ios-session-default-seed-$RUN_STAMP.txt" 2>&1
  fi

  XDG_DATA_HOME="$opencode_data_home" \
  GT_OPENCODE_DB_PATH="$opencode_data_home/opencode/opencode.db" \
  GT_OPENCODE_HOSTED_DATA_HOME="$opencode_data_home" \
  GLASSTUNNEL_DEV=1 \
  GLASSTUNNEL_KEYCHAIN_SUFFIX="${GT_OPENCODE_IOS_KEY_SUFFIX:-opencode-ios-safari-$RUN_STAMP}" \
  GT_TERMINAL_LIVE_HOST_SECONDS="${GT_OPENCODE_IOS_HOST_SECONDS:-360}" \
  GT_TERMINAL_LIVE_HOST_LABEL="$host_label" \
  swift run --package-path "$ROOT_DIR/apps/host-macos" TerminalLiveHostHarness >"$host_log" 2>&1 &
  host_pid="$!"
  linked_host_started=1

  local deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$host_pid" 2>/dev/null; then
      echo "OpenCode iOS host harness exited before link code." >&2
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

  echo "Timed out waiting for OpenCode iOS host link code." >&2
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
  if [[ "$status" -ne 0 && "$script_completed" != "1" ]]; then
    write_artifact failed "Script exited before completion" || true
  fi
  cleanup_host
  rm -f "$click_helper"
  exit "$status"
}

trap on_exit EXIT

start_host_harness

workspace_ocr_seen() {
  local text_file="$1"
  rg -q "Connected|Runs on your Mac|Send a prompt|Type a terminal command|Start OpenCode on this Mac|OpenCode context synced|WORKING|READY|RUNNING" "$text_file" &&
    ! rg -q "Your Macs|Mac added|Add another Mac|One-time code|Add this Mac" "$text_file"
}

opencode_start_card_seen() {
  local text_file="$1"
  rg -q "OpenCode is ready|Start OpenCode on this Mac|\\bStart\\b" "$text_file"
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
      if rg -q "Mac added|Open|$host_label|Your Macs|Connected|Runs on your Mac|Send a prompt" "$link_text"; then
        link_state_seen=1
        break
      fi
      sleep 2
    done
  fi

  assert_ocr_contains link "$link_text" "Mac added|Open|$host_label|Your Macs|Connected|Runs on your Mac|Send a prompt"

  if ! workspace_ocr_seen "$link_text"; then
    echo "Opening the linked Mac from the account host list."
    tap "$open_host_x_ratio" "$open_host_y_ratio"
    sleep "$LINK_WAIT_SECONDS"
    xcrun simctl openurl "$DEVICE" "$URL"
    sleep "$WAIT_SECONDS"

    capture_into linked
    linked_screenshot="$capture_screenshot"
    linked_text="$capture_text"
    assert_ocr_contains linked "$linked_text" "Connected|Runs on your Mac|Send a prompt|Type a terminal command|Start OpenCode on this Mac|OpenCode context synced|WORKING|READY|RUNNING"

    initial_screenshot="$linked_screenshot"
    initial_text="$linked_text"
  else
    initial_screenshot="$link_screenshot"
    initial_text="$link_text"
  fi
fi

if ! workspace_ocr_seen "$initial_text"; then
  echo "Result: failed; iOS Simulator Safari did not open an OpenCode workspace." >&2
  echo "OCR text: $initial_text" >&2
  exit 1
fi

if opencode_start_card_seen "$initial_text"; then
  tap "$start_x_ratio" "$start_y_ratio"
  sleep "$START_WAIT_SECONDS"
fi

capture_into started
started_screenshot="$capture_screenshot"
started_text="$capture_text"
if opencode_start_card_seen "$started_text"; then
  tap "$start_x_ratio" "$start_y_ratio"
  sleep "$START_WAIT_SECONDS"
  capture_into started
  started_screenshot="$capture_screenshot"
  started_text="$capture_text"
fi
assert_ocr_contains started "$started_text" "OpenCode|WORKING|READY|RUNNING|Send a prompt|Type a terminal command"
if rg -q "OFFLINE|Mac offline|Connection issue" "$started_text"; then
  write_artifact failed "Temporary OpenCode host was offline before prompt submission"
  echo "Result: failed; iOS Simulator Safari opened the temporary OpenCode host, but the workspace stayed offline before prompt submission." >&2
  echo "Artifact: $ARTIFACT_PATH" >&2
  if [[ -n "$host_log" ]]; then
    echo "Host log: $host_log" >&2
  fi
  exit 1
fi
if opencode_start_card_seen "$started_text"; then
  write_artifact failed "OpenCode stayed on the start card after tapping Start"
  echo "Result: failed; iOS Simulator Safari stayed on the OpenCode start card after tapping Start." >&2
  echo "Artifact: $ARTIFACT_PATH" >&2
  exit 1
fi

if [[ "$session_switch_enabled" == "1" ]]; then
  if [[ -z "$session_switch_marker" || -z "$session_switch_label" ]]; then
    write_artifact failed "Session-switch mode did not seed OpenCode session metadata"
    echo "Result: failed; iOS Simulator Safari session-switch mode did not seed session metadata." >&2
    echo "Artifact: $ARTIFACT_PATH" >&2
    exit 1
  fi

  if rg -q "gt-opencode-ios-|OpenCode context synced|$session_default_marker|$session_switch_marker" "$started_text"; then
    sessionTargetsVisible=1
  fi

  capture_into session-before
  session_before_screenshot="$capture_screenshot"
  session_before_text="$capture_text"
  if rg -q "gt-opencode-ios-|OpenCode context synced|$session_default_marker|$session_switch_marker" "$session_before_text"; then
    sessionTargetsVisible=1
  fi

  tap "$session_switch_x_ratio" "$session_switch_y_ratio"
  sessionSwitchRequested=1
  sleep "${GT_OPENCODE_IOS_SESSION_SWITCH_WAIT:-8}"

  capture_into session-after
  session_after_screenshot="$capture_screenshot"
  session_after_text="$capture_text"
  if rg -q "$session_switch_marker" "$session_after_text"; then
    sessionSwitchHistoryVisible=1
  fi

  if [[ "$sessionTargetsVisible" != "1" || "$sessionSwitchHistoryVisible" != "1" ]]; then
    write_artifact failed "Session switch target or switched history marker was not visible in OCR"
    echo "Result: failed; iOS Simulator Safari did not prove OpenCode session switching." >&2
    echo "Session targets visible: $sessionTargetsVisible" >&2
    echo "Session switch requested: $sessionSwitchRequested" >&2
    echo "Session switch history visible: $sessionSwitchHistoryVisible" >&2
    echo "Artifact: $ARTIFACT_PATH" >&2
    echo "Session-before screenshot: $session_before_screenshot" >&2
    echo "Session-before OCR text: $session_before_text" >&2
    echo "Session-after screenshot: $session_after_screenshot" >&2
    echo "Session-after OCR text: $session_after_text" >&2
    exit 1
  fi

  write_artifact passed
  script_completed=1

  echo "Result: passed; iOS Simulator Safari switched OpenCode to a seeded non-default session."
  echo "Session default label: $session_default_label"
  echo "Session switch label: $session_switch_label"
  echo "Session switch marker: $session_switch_marker"
  echo "Artifact: $ARTIFACT_PATH"
  echo "Started screenshot: $started_screenshot"
  echo "Started OCR text: $started_text"
  echo "Session-before screenshot: $session_before_screenshot"
  echo "Session-before OCR text: $session_before_text"
  echo "Session-after screenshot: $session_after_screenshot"
  echo "Session-after OCR text: $session_after_text"
  echo "Device: $DEVICE"
  exit 0
fi

tap "$composer_x_ratio" "$composer_y_ratio"
sleep 0.4
type_text "$prompt"
sleep 0.8

capture_into typed
typed_screenshot="$capture_screenshot"
typed_text="$capture_text"
assert_ocr_contains typed "$typed_text" "$marker"
typedMarkerSeen=1

tap "$send_x_ratio" "$send_y_ratio"
sleep "$SUBMITTED_WAIT_SECONDS"

capture_into submitted
submitted_screenshot="$capture_screenshot"
submitted_text="$capture_text"
if rg -q "$marker" "$submitted_text"; then
  submittedMarkerSeen=1
  marker_seen=1
fi

if rg -q "WORKING|RUNNING|Stop response|Stop requested" "$submitted_text"; then
  prompt_screenshot="$submitted_screenshot"
  prompt_text="$submitted_text"
  promptStateSeen=1
else
  sleep "$PROMPT_WAIT_SECONDS"

  capture_into prompt
  prompt_screenshot="$capture_screenshot"
  prompt_text="$capture_text"
  assert_ocr_contains prompt "$prompt_text" "WORKING|RUNNING|Stop response|Stop requested"
  promptStateSeen=1
fi
if rg -q "$marker" "$prompt_text"; then
  marker_seen=1
fi

tap "$send_x_ratio" "$send_y_ratio"
sleep "$STOP_WAIT_SECONDS"

capture_into stop
stop_screenshot="$capture_screenshot"
stop_text="$capture_text"
assert_ocr_contains stop "$stop_text" "Stop requested|READY|ready|OpenCode is ready|stopped|interrupt|Interrupted"
if rg -q "Stop requested|READY|ready|OpenCode is ready|stopped|interrupt|Interrupted" "$stop_text"; then
  stopStateSeen=1
fi
if rg -q "$marker" "$stop_text"; then
  marker_seen=1
fi

if [[ "$strict_marker_required" == "1" && "$marker_seen" != "1" ]]; then
  write_artifact failed "Marker was not visible in submitted, prompt, or stop OCR capture"
  echo "Result: failed; iOS Simulator Safari requested Stop but OCR did not see the OpenCode marker after submission." >&2
  echo "Artifact: $ARTIFACT_PATH" >&2
  exit 1
fi

write_artifact passed
script_completed=1

echo "Result: passed; iOS Simulator Safari started OpenCode, sent a bounded prompt, and requested stop."
echo "Marker: $marker"
echo "Marker seen: $marker_seen"
echo "Typed marker seen: $typedMarkerSeen"
echo "Submitted marker seen: $submittedMarkerSeen"
echo "Prompt state seen: $promptStateSeen"
echo "Stop state seen: $stopStateSeen"
echo "Artifact: $ARTIFACT_PATH"
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
