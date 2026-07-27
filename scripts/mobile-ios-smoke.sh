#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_MOBILE_QA_OUT_DIR:-/tmp/glasstunnel-mobile-qa}"
URL="${GT_MOBILE_QA_URL:-https://app.glasstunnel.io/?mobileSmoke=$(date +%Y%m%d%H%M%S)}"
WAIT_SECONDS="${GT_MOBILE_QA_WAIT:-6}"
DEVICE="${GT_MOBILE_QA_DEVICE:-}"
SIMCTL_TIMEOUT_SECONDS="${GT_MOBILE_QA_SIMCTL_TIMEOUT:-60}"
OPENURL_ATTEMPTS="${GT_MOBILE_QA_OPENURL_ATTEMPTS:-3}"
OPENURL_RETRY_DELAY_SECONDS="${GT_MOBILE_QA_OPENURL_RETRY_DELAY:-4}"

mkdir -p "$OUT_DIR"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is required. Install Xcode and run this on macOS." >&2
  exit 1
fi

print_simctl_diagnostics() {
  echo >&2
  echo "CoreSimulator is not ready for mobile smoke testing." >&2
  echo "Diagnostics:" >&2
  echo "  Xcode: $(xcode-select -p 2>/dev/null || echo 'not selected')" >&2
  echo "  simctl: $(xcrun --find simctl 2>/dev/null || echo 'not found')" >&2
  echo "  Simulator processes:" >&2
  pgrep -fl 'CoreSimulator|Simulator|simctl' 2>/dev/null | sed 's/^/    /' >&2 || echo "    none" >&2
  echo >&2
  echo "Try:" >&2
  echo "  1. Open Xcode once and accept any first-launch prompts." >&2
  echo "  2. Open Simulator once from Xcode or with: open -a Simulator" >&2
  echo "  3. If CoreSimulator is stuck: killall -9 com.apple.CoreSimulator.CoreSimulatorService Simulator" >&2
  echo "  4. Retry with a longer timeout: GT_MOBILE_QA_SIMCTL_TIMEOUT=90 pnpm qa:mobile:ios" >&2
}

run_with_timeout_raw() {
  local timeout="$1"
  shift
  set +e
  python3 - "$timeout" "$@" <<'PY'
import subprocess
import sys

timeout = float(sys.argv[1])
cmd = sys.argv[2:]
try:
    subprocess.run(cmd, check=True, timeout=timeout)
except subprocess.TimeoutExpired:
    print(f"Timed out after {timeout:g}s: {' '.join(cmd)}", file=sys.stderr)
    sys.exit(124)
except subprocess.CalledProcessError as error:
    print(f"Command failed with exit code {error.returncode}: {' '.join(cmd)}", file=sys.stderr)
    sys.exit(error.returncode)
PY
  local status=$?
  set -e
  return "$status"
}

run_with_timeout() {
  local timeout="$1"
  shift
  set +e
  run_with_timeout_raw "$timeout" "$@"
  local status=$?
  set -e
  if [[ "$status" -ne 0 && "${1:-}" == "xcrun" && "${2:-}" == "simctl" ]]; then
    print_simctl_diagnostics
  fi
  return "$status"
}

retry_with_timeout() {
  local label="$1"
  local attempts="$2"
  local delay="$3"
  local timeout="$4"
  shift 4
  local attempt=1
  local status=0

  while [[ "$attempt" -le "$attempts" ]]; do
    if run_with_timeout_raw "$timeout" "$@"; then
      return 0
    fi
    status=$?
    if [[ "$attempt" -lt "$attempts" ]]; then
      echo "$label failed on attempt $attempt/$attempts. Retrying in ${delay}s..." >&2
      sleep "$delay"
    fi
    attempt=$((attempt + 1))
  done

  if [[ "${1:-}" == "xcrun" && "${2:-}" == "simctl" ]]; then
    print_simctl_diagnostics
  fi
  return "$status"
}

if [[ -z "$DEVICE" ]]; then
  DEVICE_ERR="$(mktemp)"
  set +e
  DEVICE="$(python3 - "$SIMCTL_TIMEOUT_SECONDS" <<'PY' 2>"$DEVICE_ERR"
import json
import subprocess
import sys

timeout = float(sys.argv[1])

def load_devices(args):
    cmd = ["xcrun", "simctl", "list", "devices", *args, "-j"]
    try:
        data = subprocess.check_output(cmd, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"Timed out after {timeout:g}s: {' '.join(cmd)}", file=sys.stderr)
        sys.exit(124)
    return json.loads(data).get("devices", {})

for runtime_devices in load_devices(["booted"]).values():
    for device in runtime_devices:
        if device.get("state") == "Booted" and "iPhone" in device.get("name", ""):
            print(device["udid"])
            sys.exit(0)

for runtime_devices in load_devices(["available"]).values():
    for device in runtime_devices:
        if device.get("isAvailable") and "iPhone" in device.get("name", ""):
            print(device["udid"])
            sys.exit(0)

sys.exit("No available iPhone simulator found.")
PY
)"
  DEVICE_STATUS=$?
  set -e
  if [[ "$DEVICE_STATUS" -ne 0 ]]; then
    cat "$DEVICE_ERR" >&2
    rm -f "$DEVICE_ERR"
    if [[ "$DEVICE_STATUS" -eq 124 ]]; then
      print_simctl_diagnostics
    fi
    exit "$DEVICE_STATUS"
  fi
  rm -f "$DEVICE_ERR"
fi

STATE_ERR="$(mktemp)"
set +e
STATE="$(python3 - "$SIMCTL_TIMEOUT_SECONDS" "$DEVICE" <<'PY' 2>"$STATE_ERR"
import json
import subprocess
import sys

timeout = float(sys.argv[1])
target = sys.argv[2]
cmd = ["xcrun", "simctl", "list", "devices", "-j"]
try:
    raw = subprocess.check_output(cmd, text=True, timeout=timeout)
except subprocess.TimeoutExpired:
    print(f"Timed out after {timeout:g}s: {' '.join(cmd)}", file=sys.stderr)
    sys.exit(124)
data = json.loads(raw).get("devices", {})
for runtime_devices in data.values():
    for device in runtime_devices:
        if device.get("udid") == target:
            print(device.get("state", "Unknown"))
            sys.exit(0)
print("Unknown")
PY
)"
STATE_STATUS=$?
set -e
if [[ "$STATE_STATUS" -ne 0 ]]; then
  cat "$STATE_ERR" >&2
  rm -f "$STATE_ERR"
  if [[ "$STATE_STATUS" -eq 124 ]]; then
    print_simctl_diagnostics
  fi
  exit "$STATE_STATUS"
fi
rm -f "$STATE_ERR"

if [[ "$STATE" != "Booted" ]]; then
  echo "Booting iOS simulator $DEVICE..."
  run_with_timeout "$SIMCTL_TIMEOUT_SECONDS" xcrun simctl boot "$DEVICE"
fi

echo "Waiting for iOS simulator boot readiness..."
run_with_timeout "$SIMCTL_TIMEOUT_SECONDS" xcrun simctl bootstatus "$DEVICE" -b

run_with_timeout "$SIMCTL_TIMEOUT_SECONDS" open -a Simulator

echo "Opening $URL"
retry_with_timeout "Opening URL in simulator Safari" "$OPENURL_ATTEMPTS" "$OPENURL_RETRY_DELAY_SECONDS" "$SIMCTL_TIMEOUT_SECONDS" xcrun simctl openurl "$DEVICE" "$URL"

echo "Waiting ${WAIT_SECONDS}s before screenshot..."
sleep "$WAIT_SECONDS"

STAMP="$(date +%Y%m%d-%H%M%S)"
SCREENSHOT="$OUT_DIR/ios-safari-$STAMP.png"
run_with_timeout "$SIMCTL_TIMEOUT_SECONDS" xcrun simctl io "$DEVICE" screenshot "$SCREENSHOT" >/dev/null

echo "Mobile QA screenshot: $SCREENSHOT"
echo "Device: $DEVICE"
echo "Repo: $ROOT_DIR"
