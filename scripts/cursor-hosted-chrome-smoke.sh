#!/usr/bin/env bash
# Verify Cursor through the hosted PWA rendered in Chrome's mobile viewport.
#
# This uses a disposable smoke account and an isolated local host harness. It
# drives the hosted UI, starts Cursor from the web, sends a tiny marker prompt,
# then checks the real Cursor window through Accessibility for the marker
# appearing as both prompt and response. Artifacts intentionally avoid Cursor
# conversation text.
#
# Set GT_CURSOR_HOSTED_BACKGROUND_BEFORE_SUBMIT=1 to activate Finder before the
# hosted web send, proving Cursor can receive input when it is not already
# frontmost. Set GT_CURSOR_HOSTED_TARGET_SWITCH_ONLY=1 to verify hosted target
# switching without sending a prompt to Cursor. Set
# GT_CURSOR_HOSTED_PREFLIGHT_ONLY=1 to verify the visible Cursor model/settings
# allow-list without sending a prompt to Cursor.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_URL="${GT_CURSOR_HOSTED_APP_URL:-https://app.glasstunnel.io}"
DEBUG_PORT="${GT_CURSOR_HOSTED_DEBUG_PORT:-9254}"
WIDTH="${GT_CURSOR_HOSTED_WIDTH:-390}"
HEIGHT="${GT_CURSOR_HOSTED_HEIGHT:-844}"
OUT_DIR="${GT_CURSOR_HOSTED_OUT_DIR:-/tmp/glasstunnel-cursor-hosted}"
CHROME_BIN="${GT_MOBILE_CHROME_BIN:-}"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:cursor:hosted-chrome

Loads .env.platform.local and .env.smoke.local, starts an isolated local Mac
host harness, opens the hosted PWA in Chrome's mobile viewport, signs in with
the disposable email account, links the harness host, opens Cursor, sends a
tiny prompt, and verifies the real Cursor window shows the marker as submitted
and answered. This is rendered hosted Chrome evidence, not physical-phone
evidence.

Set GT_CURSOR_HOSTED_BACKGROUND_BEFORE_SUBMIT=1 to background Cursor with
Finder before sending the prompt.

Set GT_CURSOR_HOSTED_TARGET_SWITCH_ONLY=1 to verify Cursor target switching
without sending a prompt/model request.

Set GT_CURSOR_HOSTED_PREFLIGHT_ONLY=1 to verify Cursor is visible and currently
using an allowed low-cost model/settings value without sending a prompt/model
request. The default allow-list is "Composer 2.5 Fast"; override with
GT_CURSOR_ALLOWED_MODEL_SETTINGS as a comma-separated list.

Set GT_CURSOR_REQUIRE_ALLOWED_MODEL_SETTINGS=0 only with
GT_CURSOR_MODEL_SETTINGS_OVERRIDE_REASON=<short reason>. This records an
explicit override when a human has confirmed Cursor's visible low-cost setting
but automation cannot read the active selector.
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
  echo "Result: blocked; Cursor hosted Chrome smoke requires macOS." >&2
  exit 1
fi

for file in .env.platform.local .env.smoke.local; do
  if [[ ! -f "$ROOT_DIR/$file" ]]; then
    echo "Missing $file. Platform and smoke email credentials are required." >&2
    exit 2
  fi
done

set -a
# shellcheck disable=SC1091
source "$ROOT_DIR/.env.platform.local"
# shellcheck disable=SC1091
source "$ROOT_DIR/.env.smoke.local"
set +a

: "${SUPABASE_URL:?SUPABASE_URL is required in .env.platform.local}"
: "${SUPABASE_ANON_KEY:?SUPABASE_ANON_KEY is required in .env.platform.local}"
: "${SMOKE_EMAIL:?SMOKE_EMAIL is required in .env.smoke.local}"
: "${SMOKE_PASSWORD:?SMOKE_PASSWORD is required in .env.smoke.local}"

if [[ -z "$CHROME_BIN" ]]; then
  if [[ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]]; then
    CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  elif command -v google-chrome >/dev/null 2>&1; then
    CHROME_BIN="$(command -v google-chrome)"
  elif command -v chromium >/dev/null 2>&1; then
    CHROME_BIN="$(command -v chromium)"
  fi
fi

if [[ -z "$CHROME_BIN" || ! -x "$CHROME_BIN" ]]; then
  echo "Chrome executable not found. Set GT_MOBILE_CHROME_BIN to run this smoke." >&2
  exit 1
fi

if [[ ! -d "/Applications/Cursor.app" && ! -d "$HOME/Applications/Cursor.app" ]]; then
  echo "Cursor.app is not installed in /Applications or ~/Applications." >&2
  exit 1
fi

cd "$ROOT_DIR"
mkdir -p "$OUT_DIR"
run_stamp="$(date +%Y%m%d%H%M%S)"
host_label="${GT_CURSOR_HOSTED_HOST_LABEL:-Cursor hosted Chrome $run_stamp}"

probe_file="$(mktemp -t glasstunnel-cursor-window-probe.XXXXXX.swift)"
cat >"$probe_file" <<'SWIFT'
import AppKit
import ApplicationServices
import Foundation

let bundleID = "com.todesktop.230313mzl4w4u92"
let marker = ProcessInfo.processInfo.environment["GT_CURSOR_HOSTED_MARKER"] ?? ""

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

host_log="$(mktemp -t glasstunnel-cursor-hosted-host.XXXXXX.log)"
host_pid=""
cleanup() {
  rm -f "$probe_file"
  if [[ -n "$host_pid" ]] && kill -0 "$host_pid" 2>/dev/null; then
    kill "$host_pid" 2>/dev/null || true
    wait "$host_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

GLASSTUNNEL_DEV=1 \
GLASSTUNNEL_KEYCHAIN_SUFFIX="${GT_CURSOR_HOSTED_KEY_SUFFIX:-cursor-hosted-chrome-$run_stamp}" \
GT_TERMINAL_LIVE_HOST_SECONDS="${GT_CURSOR_HOSTED_HOST_SECONDS:-300}" \
GT_TERMINAL_LIVE_HOST_LABEL="$host_label" \
swift run --package-path apps/host-macos TerminalLiveHostHarness >"$host_log" 2>&1 &
host_pid="$!"

host_device_id=""
link_code=""
deadline=$((SECONDS + 60))
while (( SECONDS < deadline )); do
  if ! kill -0 "$host_pid" 2>/dev/null; then
    echo "Cursor hosted host harness exited before link code." >&2
    sed -E 's/(token|password|secret|key)=([^[:space:]]+)/\1=<redacted>/Ig' "$host_log" >&2 || true
    exit 1
  fi
  host_device_id="$(awk '/^HOST_DEVICE_ID / { print $2; exit }' "$host_log")"
  link_code="$(awk '/^LINK_CODE / { print $2; exit }' "$host_log")"
  if [[ -n "$host_device_id" && -n "$link_code" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$host_device_id" || -z "$link_code" ]]; then
  echo "Timed out waiting for Cursor hosted host link code." >&2
  sed -E 's/(token|password|secret|key)=([^[:space:]]+)/\1=<redacted>/Ig' "$host_log" >&2 || true
  exit 1
fi

access_token="$(
  node <<'NODE'
const url = process.env.SUPABASE_URL;
const anon = process.env.SUPABASE_ANON_KEY;
const email = process.env.SMOKE_EMAIL;
const password = process.env.SMOKE_PASSWORD;

const response = await fetch(`${url.replace(/\/+$/, '')}/auth/v1/token?grant_type=password`, {
  method: 'POST',
  headers: {
    apikey: anon,
    authorization: `Bearer ${anon}`,
    'content-type': 'application/json',
  },
  body: JSON.stringify({ email, password }),
});

const payload = await response.json().catch(() => ({}));
if (!response.ok || !payload.access_token) {
  const reason = payload.error_description || payload.msg || payload.error || 'unknown error';
  console.error(`smoke account auth failed with ${response.status}: ${reason}`);
  process.exit(1);
}

process.stdout.write(payload.access_token);
NODE
)"

GT_CURSOR_HOSTED_CHROME="$CHROME_BIN" \
GT_CURSOR_HOSTED_APP_URL="$APP_URL" \
GT_CURSOR_HOSTED_DEBUG_PORT="$DEBUG_PORT" \
GT_CURSOR_HOSTED_WIDTH="$WIDTH" \
GT_CURSOR_HOSTED_HEIGHT="$HEIGHT" \
GT_CURSOR_HOSTED_OUT_DIR="$OUT_DIR" \
GT_CURSOR_HOSTED_HOST_DEVICE_ID="$host_device_id" \
GT_CURSOR_HOSTED_HOST_LABEL="$host_label" \
GT_CURSOR_HOSTED_LINK_CODE="$link_code" \
GT_CURSOR_HOSTED_EMAIL="$SMOKE_EMAIL" \
GT_CURSOR_HOSTED_PASSWORD="$SMOKE_PASSWORD" \
GT_CURSOR_HOSTED_ACCESS_TOKEN="$access_token" \
GT_CURSOR_HOSTED_WINDOW_PROBE="$probe_file" \
GT_CURSOR_HOSTED_BACKGROUND_BEFORE_SUBMIT="${GT_CURSOR_HOSTED_BACKGROUND_BEFORE_SUBMIT:-0}" \
GT_CURSOR_HOSTED_TARGET_SWITCH_ONLY="${GT_CURSOR_HOSTED_TARGET_SWITCH_ONLY:-0}" \
GT_CURSOR_HOSTED_PREFLIGHT_ONLY="${GT_CURSOR_HOSTED_PREFLIGHT_ONLY:-0}" \
GT_CURSOR_ALLOWED_MODEL_SETTINGS="${GT_CURSOR_ALLOWED_MODEL_SETTINGS:-Composer 2.5 Fast}" \
node <<'NODE'
const { spawn, spawnSync } = await import("node:child_process");
const fs = await import("node:fs/promises");
const os = await import("node:os");
const path = await import("node:path");

const chromeBin = process.env.GT_CURSOR_HOSTED_CHROME;
const appUrl = process.env.GT_CURSOR_HOSTED_APP_URL.replace(/\/+$/, "");
const debugPort = process.env.GT_CURSOR_HOSTED_DEBUG_PORT;
const width = Number(process.env.GT_CURSOR_HOSTED_WIDTH || "390");
const height = Number(process.env.GT_CURSOR_HOSTED_HEIGHT || "844");
const outDir = process.env.GT_CURSOR_HOSTED_OUT_DIR || "/tmp/glasstunnel-cursor-hosted";
const hostDeviceId = process.env.GT_CURSOR_HOSTED_HOST_DEVICE_ID;
const hostLabel = process.env.GT_CURSOR_HOSTED_HOST_LABEL || "Cursor hosted smoke host";
const linkCode = process.env.GT_CURSOR_HOSTED_LINK_CODE;
const email = process.env.GT_CURSOR_HOSTED_EMAIL;
const password = process.env.GT_CURSOR_HOSTED_PASSWORD;
const accessToken = process.env.GT_CURSOR_HOSTED_ACCESS_TOKEN;
const probeFile = process.env.GT_CURSOR_HOSTED_WINDOW_PROBE;
const signaling = process.env.GT_TERMINAL_LIVE_SIGNALING_URL || "wss://signaling.glasstunnel.io/signal";
const apiBase = signaling.replace(/^ws/i, "http").replace(/\/signal\/?$/, "");
const startedAt = Date.now();
const marker = `GT_CURSOR_HOSTED_${startedAt}`;
const prompt = process.env.GT_CURSOR_HOSTED_PROMPT || `Reply exactly: ${marker}`;
const backgroundBeforeSubmit = process.env.GT_CURSOR_HOSTED_BACKGROUND_BEFORE_SUBMIT === "1";
const targetSwitchOnly = process.env.GT_CURSOR_HOSTED_TARGET_SWITCH_ONLY === "1";
const preflightOnly = process.env.GT_CURSOR_HOSTED_PREFLIGHT_ONLY === "1";
const requireAllowedModelSettings = process.env.GT_CURSOR_REQUIRE_ALLOWED_MODEL_SETTINGS !== "0";
const modelSettingsOverrideReason = String(process.env.GT_CURSOR_MODEL_SETTINGS_OVERRIDE_REASON || "").trim();
const modelSettingsOverrideSource = String(process.env.GT_CURSOR_MODEL_SETTINGS_OVERRIDE_SOURCE || "").trim();
const normalizeModelSettings = (value) =>
  String(value || "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
const allowedModelSettings = String(process.env.GT_CURSOR_ALLOWED_MODEL_SETTINGS || "")
  .split(",")
  .map((value) => value.trim())
  .filter(Boolean);
const allowedModelSettingsNormalized = allowedModelSettings.map(normalizeModelSettings);
const profile = await fs.mkdtemp(path.join(os.tmpdir(), "gt-cursor-hosted-chrome."));
const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
const screenshotPath = path.join(outDir, `chrome-mobile-cursor-hosted-${timestamp}.png`);
const artifactPath = path.join(outDir, `cursor-hosted-chrome-${timestamp}.json`);
const observed = {
  ok: false,
  appUrl,
  hostDeviceId,
  hostLabel,
  chromeExitCode: null,
  chromeErrorTail: "",
  cursorStartedFromWeb: false,
  backgroundBeforeSubmit,
  targetSwitchOnly,
  preflightOnly,
  allowedModelSettings,
  requireAllowedModelSettings,
  modelSettingsOverrideReason: modelSettingsOverrideReason || null,
  modelSettingsOverrideSource: modelSettingsOverrideSource || null,
  modelSettingsOverrideUsed: false,
  targetButtonCountBefore: null,
  targetButtonCountAfter: null,
  targetSwitchCandidateFound: false,
  targetSwitchRequested: false,
  targetSwitchSelected: false,
  targetSwitchingStateSeen: false,
  modelSettingsPreflightRecorded: false,
  modelSettingsPreflight: null,
  modelSettingsAllowed: !requireAllowedModelSettings,
  promptBlockedBeforeSubmit: false,
  cursorActivatedForPreflight: false,
  cursorActivationMethod: null,
  cursorActivationError: null,
  cursorWindowAvailableBeforeBackground: null,
  cursorBackgroundedBeforeSubmit: false,
  cursorBackgroundMethod: null,
  cursorBackgroundAttemptError: null,
  promptSentFromWeb: false,
  cursorWindowAvailable: false,
  markerSeenAsPromptAndResponse: false,
  markerOccurrences: 0,
  modelSettingsRecorded: false,
  modelSettings: null,
  screenshot: screenshotPath,
};
let sendCommandForCleanup = null;

await fs.mkdir(outDir, { recursive: true });

const chrome = spawn(
  chromeBin,
  [
    "--headless=new",
    "--disable-gpu",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-sync",
    "--disable-extensions",
    "--disable-default-apps",
    "--disable-crash-reporter",
    "--disable-breakpad",
    "--metrics-recording-only",
    "--disable-features=MediaRouter,OptimizationHints,AutofillServerCommunication,CertificateTransparencyComponentUpdater",
    "--log-level=3",
    "--no-first-run",
    "--no-default-browser-check",
    "--remote-debugging-address=127.0.0.1",
    `--remote-debugging-port=${debugPort}`,
    `--user-data-dir=${profile}`,
    `--window-size=${width},${height}`,
    "--force-device-scale-factor=2",
    "--user-agent=Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/149.0.0.0 Mobile/15E148 Safari/604.1",
    "about:blank",
  ],
  { stdio: ["ignore", "ignore", "pipe"] },
);
const chromeErrors = [];
chrome.stderr?.on("data", (chunk) => {
  chromeErrors.push(String(chunk));
  while (chromeErrors.join("").length > 4000) chromeErrors.shift();
});
chrome.on("exit", (code) => {
  observed.chromeExitCode = code;
});

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function cleanup() {
  chrome.kill("SIGTERM");
  await fs.rm(profile, { recursive: true, force: true });
}

async function writeArtifact(error) {
  observed.chromeErrorTail = chromeErrors.join("").slice(-1200);
  const payload = {
    ...observed,
    ok:
      !error &&
      observed.cursorStartedFromWeb &&
      (observed.targetSwitchOnly
        ? observed.targetButtonCountBefore >= 2 &&
          observed.targetButtonCountAfter >= 2 &&
          observed.targetSwitchCandidateFound &&
          observed.targetSwitchRequested &&
          observed.targetSwitchSelected &&
          observed.targetSwitchingStateSeen
        : true) &&
      (!observed.backgroundBeforeSubmit ||
        (observed.cursorWindowAvailableBeforeBackground && observed.cursorBackgroundedBeforeSubmit)) &&
      (!observed.requireAllowedModelSettings || observed.modelSettingsAllowed) &&
      (!observed.preflightOnly || observed.modelSettingsPreflightRecorded) &&
      (observed.targetSwitchOnly ||
        observed.preflightOnly ||
        (observed.promptSentFromWeb &&
          observed.cursorWindowAvailable &&
          observed.markerSeenAsPromptAndResponse &&
          observed.modelSettingsRecorded)),
    error: error ? String(error.message || error) : undefined,
  };
  await fs.writeFile(artifactPath, `${JSON.stringify(payload, null, 2)}\n`);
  return payload;
}

try {
  const fetchJson = async (url, label, init) => {
    let response;
    try {
      response = await fetch(url, init);
    } catch (error) {
      throw new Error(`${label} fetch failed: ${error instanceof Error ? error.message : String(error)}`);
    }
    if (!response.ok) {
      throw new Error(`${label} failed with ${response.status}`);
    }
    return response.json();
  };

  let chromeReady = false;
  for (let i = 0; i < 80; i += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${debugPort}/json/version`);
      if (response.ok) {
        chromeReady = true;
        break;
      }
    } catch {
      // Retry until Chrome exposes the debugging endpoint.
    }
    if (chrome.exitCode !== null) break;
    await sleep(100);
  }
  if (!chromeReady) {
    throw new Error(`Chrome debugging endpoint did not become ready. exitCode=${chrome.exitCode ?? "running"}`);
  }

  const targetUrl = `${appUrl}/?${new URLSearchParams({ cursorSmoke: String(startedAt) }).toString()}`;
  const tab = await fetchJson(`http://127.0.0.1:${debugPort}/json/new?${encodeURIComponent(targetUrl)}`, "Chrome new tab", {
    method: "PUT",
  });
  const socket = new WebSocket(tab.webSocketDebuggerUrl);
  const pending = new Map();
  let id = 0;

  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      pending.get(message.id)(message);
      pending.delete(message.id);
    }
  };

  await new Promise((resolve) => {
    socket.onopen = resolve;
  });

  const send = (method, params = {}) =>
    new Promise((resolve) => {
      const message = { id: ++id, method, params };
      pending.set(message.id, resolve);
      socket.send(JSON.stringify(message));
    });
  sendCommandForCleanup = send;

  const evaluate = async (expression) => {
    const response = await send("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (response.error) {
      throw new Error(response.error.message || "Chrome evaluation protocol error");
    }
    if (!response.result) {
      throw new Error(`Chrome evaluation returned no result: ${JSON.stringify(response).slice(0, 300)}`);
    }
    if (response.result.exceptionDetails) {
      throw new Error(response.result.exceptionDetails.text || "Chrome evaluation failed");
    }
    return response.result.result.value;
  };

  const bodyText = () => evaluate(`document.body.innerText`);
  const waitFor = async (label, predicateSource, timeoutMs = 45_000) => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const result = await evaluate(`(() => { ${predicateSource} })()`);
      if (result) return result;
      await sleep(250);
    }
    throw new Error(`Timed out waiting for ${label}.`);
  };

  const clickButton = async (label, timeoutMs = 20_000) => {
    await waitFor(
      `button ${label}`,
      `return Array.from(document.querySelectorAll("button")).some((button) => button.innerText.trim() === ${JSON.stringify(label)} && !button.disabled);`,
      timeoutMs,
    );
    const clicked = await evaluate(`(() => {
      const button = Array.from(document.querySelectorAll("button")).find((candidate) => candidate.innerText.trim() === ${JSON.stringify(label)} && !candidate.disabled);
      if (!button) return false;
      button.click();
      return true;
    })()`);
    if (!clicked) throw new Error(`Could not click button ${label}`);
  };

  const clickLastButton = async (label, timeoutMs = 20_000) => {
    await waitFor(
      `last button ${label}`,
      `return Array.from(document.querySelectorAll("button")).some((button) => button.innerText.trim() === ${JSON.stringify(label)} && !button.disabled);`,
      timeoutMs,
    );
    const clicked = await evaluate(`(() => {
      const buttons = Array.from(document.querySelectorAll("button")).filter((candidate) => candidate.innerText.trim() === ${JSON.stringify(label)} && !candidate.disabled);
      const button = buttons.at(-1);
      if (!button) return false;
      button.click();
      return true;
    })()`);
    if (!clicked) throw new Error(`Could not click last button ${label}`);
  };

  const clickAnyButton = async (labels, timeoutMs = 20_000) => {
    const encoded = JSON.stringify(labels);
    await waitFor(
      `one of buttons ${labels.join(", ")}`,
      `const labels = ${encoded}; return Array.from(document.querySelectorAll("button")).some((button) => labels.includes(button.innerText.trim()) && !button.disabled);`,
      timeoutMs,
    );
    const clicked = await evaluate(`(() => {
      const labels = ${encoded};
      const button = Array.from(document.querySelectorAll("button")).find((candidate) => labels.includes(candidate.innerText.trim()) && !candidate.disabled);
      if (!button) return false;
      button.click();
      return true;
    })()`);
    if (!clicked) throw new Error(`Could not click any button: ${labels.join(", ")}`);
  };

  const visibleButtonPredicate = (matcherSource) => `
    const visible = (button) => {
      const rect = button.getBoundingClientRect();
      const style = window.getComputedStyle(button);
      return rect.width > 0 &&
        rect.height > 0 &&
        style.display !== "none" &&
        style.visibility !== "hidden" &&
        style.pointerEvents !== "none";
    };
    return Array.from(document.querySelectorAll("button")).some((button) =>
      (${matcherSource}) && !button.disabled && visible(button)
    );
  `;

  const visibleButtonClickSource = (matcherSource) => `
    const visible = (button) => {
      const rect = button.getBoundingClientRect();
      const style = window.getComputedStyle(button);
      return rect.width > 0 &&
        rect.height > 0 &&
        style.display !== "none" &&
        style.visibility !== "hidden" &&
        style.pointerEvents !== "none";
    };
    const button = Array.from(document.querySelectorAll("button")).find((candidate) =>
      (${matcherSource.replaceAll("button", "candidate")}) && !candidate.disabled && visible(candidate)
    );
    if (!button) return false;
    button.click();
    return true;
  `;

  const targetButtonsSnapshot = () => evaluate(`(() => {
    const visible = (button) => {
      const rect = button.getBoundingClientRect();
      const style = window.getComputedStyle(button);
      return rect.width > 0 &&
        rect.height > 0 &&
        style.display !== "none" &&
        style.visibility !== "hidden" &&
        style.pointerEvents !== "none";
    };
    const buttons = Array.from(document.querySelectorAll("button"))
      .filter((button) => {
        const label = button.getAttribute("aria-label") || "";
        return visible(button) && (
          label.startsWith("Switch to ") ||
          label.startsWith("Current session: ")
        );
      });
    return {
      count: buttons.length,
      currentCount: buttons.filter((button) => (button.getAttribute("aria-label") || "").startsWith("Current session: ")).length,
      switchCount: buttons.filter((button) => (button.getAttribute("aria-label") || "").startsWith("Switch to ")).length,
    };
  })()`);

  const clickFirstSwitchableTarget = async (timeoutMs = 20_000) => {
    const matcher = `(button.getAttribute("aria-label") || "").startsWith("Switch to ")`;
    await waitFor("switchable Cursor target", visibleButtonPredicate(matcher), timeoutMs);
    const clicked = await evaluate(`(() => { ${visibleButtonClickSource(matcher)} })()`);
    if (!clicked) throw new Error("Could not click switchable Cursor target");
  };

  const cursorReadyPredicate = `
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = window.getComputedStyle(element);
      return rect.width > 0 &&
        rect.height > 0 &&
        style.display !== "none" &&
        style.visibility !== "hidden" &&
        style.pointerEvents !== "none";
    };
    const text = document.body.innerText;
    const visibleComposer = Array.from(document.querySelectorAll('textarea[placeholder*="prompt"]')).some(visible);
    const visibleTarget = Array.from(document.querySelectorAll("button")).some((button) => {
      const label = button.getAttribute("aria-label") || "";
      return visible(button) && (label.startsWith("Switch to ") || label.startsWith("Current session: "));
    });
    return visibleComposer ||
      visibleTarget ||
      text.includes("Start Cursor on this Mac.") ||
      text.includes("Open Cursor on this Mac");
  `;

  const visibleCursorComposer = () => evaluate(`(() => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = window.getComputedStyle(element);
      return rect.width > 0 &&
        rect.height > 0 &&
        style.display !== "none" &&
        style.visibility !== "hidden" &&
        style.pointerEvents !== "none";
    };
    return Array.from(document.querySelectorAll('textarea[placeholder*="prompt"]')).some(visible);
  })()`);

  const clickHostButton = async (hostName, labels, timeoutMs = 20_000) => {
    const encodedHost = JSON.stringify(hostName);
    const encodedLabels = JSON.stringify(labels);
    const candidateSource = `
      const hostName = ${encodedHost};
      const labels = ${encodedLabels};
      const buttons = Array.from(document.querySelectorAll("button"));
      for (const button of buttons) {
        if (!labels.includes(button.innerText.trim()) || button.disabled) continue;
        let node = button;
        for (let depth = 0; node && depth < 8; depth += 1, node = node.parentElement) {
          if (node.innerText && node.innerText.includes(hostName)) return button;
        }
      }
      return null;
    `;
    await waitFor(`host ${hostName} button`, `return Boolean((() => { ${candidateSource} })());`, timeoutMs);
    const clicked = await evaluate(`(() => {
      const button = (() => { ${candidateSource} })();
      if (!button) return false;
      button.click();
      return true;
    })()`);
    if (!clicked) throw new Error(`Could not click host ${hostName} button`);
  };

  const clickButtonByAria = async (label, timeoutMs = 20_000) => {
    await waitFor(
      `button aria-label ${label}`,
      `return Array.from(document.querySelectorAll("button")).some((button) => (button.getAttribute("aria-label") === ${JSON.stringify(label)} || button.title === ${JSON.stringify(label)}) && !button.disabled);`,
      timeoutMs,
    );
    const clicked = await evaluate(`(() => {
      const button = Array.from(document.querySelectorAll("button")).find((candidate) => (candidate.getAttribute("aria-label") === ${JSON.stringify(label)} || candidate.title === ${JSON.stringify(label)}) && !candidate.disabled);
      if (!button) return false;
      button.click();
      return true;
    })()`);
    if (!clicked) throw new Error(`Could not click ${label}`);
  };

  const fillInput = async (selector, value) => {
    const ok = await evaluate(`(() => {
      const input = document.querySelector(${JSON.stringify(selector)});
      if (!input) return false;
      input.focus();
      const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(input), "value")?.set;
      if (setter) {
        setter.call(input, ${JSON.stringify(value)});
      } else {
        input.value = ${JSON.stringify(value)};
      }
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
      return true;
    })()`);
    if (!ok) throw new Error(`Could not fill ${selector}`);
  };

  const runCursorProbe = () => {
    const result = spawnSync("/usr/bin/swift", [probeFile], {
      env: { ...process.env, GT_CURSOR_HOSTED_MARKER: marker },
      encoding: "utf8",
      maxBuffer: 1024 * 1024,
    });
    if (result.error) throw result.error;
    if (result.status !== 0) {
      throw new Error(`Cursor window probe failed with exit ${result.status}: ${result.stderr || result.stdout}`);
    }
    return JSON.parse(result.stdout);
  };

  const activateCursorForPreflight = () => {
    const bundleResult = spawnSync("/usr/bin/open", ["-b", "com.todesktop.230313mzl4w4u92"], {
      encoding: "utf8",
      maxBuffer: 1024 * 1024,
    });
    if (!bundleResult.error && bundleResult.status === 0) {
      observed.cursorActivatedForPreflight = true;
      observed.cursorActivationMethod = "open -b com.todesktop.230313mzl4w4u92";
      return;
    }

    const nameResult = spawnSync("/usr/bin/open", ["-a", "Cursor"], {
      encoding: "utf8",
      maxBuffer: 1024 * 1024,
    });
    if (nameResult.error) throw nameResult.error;
    if (nameResult.status !== 0) {
      const message = nameResult.stderr || nameResult.stdout || bundleResult.stderr || bundleResult.stdout;
      observed.cursorActivationError = message || "unknown Cursor activation failure";
      throw new Error(`Could not activate Cursor before model/settings preflight: ${observed.cursorActivationError}`);
    }

    observed.cursorActivatedForPreflight = true;
    observed.cursorActivationMethod = "open -a Cursor";
  };

  const verifyAllowedCursorModelSettings = async () => {
    if (requireAllowedModelSettings && allowedModelSettingsNormalized.length === 0) {
      observed.promptBlockedBeforeSubmit = true;
      throw new Error("Cursor model/settings preflight has no allowed model settings configured.");
    }

    if (!requireAllowedModelSettings && !modelSettingsOverrideReason) {
      observed.promptBlockedBeforeSubmit = true;
      throw new Error("Cursor model/settings override requires GT_CURSOR_MODEL_SETTINGS_OVERRIDE_REASON.");
    }

    const deadline = Date.now() + Number(process.env.GT_CURSOR_HOSTED_MODEL_PREFLIGHT_WAIT_MS || "15000");
    let latestProbe = null;
    while (Date.now() < deadline) {
      latestProbe = runCursorProbe();
      observed.cursorWindowAvailable = latestProbe.windowAvailable === true;
      observed.modelSettingsPreflightRecorded = latestProbe.modelSettingsRecorded === true;
      observed.modelSettingsPreflight = latestProbe.modelSettings || observed.modelSettingsPreflight;
      observed.modelSettingsRecorded = latestProbe.modelSettingsRecorded === true;
      observed.modelSettings = latestProbe.modelSettings || observed.modelSettings;
      if (observed.modelSettingsPreflightRecorded) break;
      await sleep(500);
    }

    if (!observed.modelSettingsPreflightRecorded || !observed.modelSettingsPreflight) {
      if (!requireAllowedModelSettings && !preflightOnly && modelSettingsOverrideReason) {
        observed.modelSettingsAllowed = true;
        observed.modelSettingsOverrideUsed = true;
        return;
      }
      observed.promptBlockedBeforeSubmit = true;
      throw new Error("Cursor model/settings preflight failed before prompt submit: visible model/settings could not be read.");
    }

    if (!requireAllowedModelSettings) {
      observed.modelSettingsAllowed = true;
      observed.modelSettingsOverrideUsed = true;
      return;
    }

    const current = normalizeModelSettings(observed.modelSettingsPreflight);
    observed.modelSettingsAllowed = allowedModelSettingsNormalized.includes(current);
    if (!observed.modelSettingsAllowed) {
      observed.promptBlockedBeforeSubmit = true;
      throw new Error(
        `Cursor model/settings preflight blocked prompt submit: visible setting "${observed.modelSettingsPreflight}" is not in allowed list: ${allowedModelSettings.join(", ")}`,
      );
    }
  };

  const backgroundCursor = () => {
    const openResult = spawnSync("/usr/bin/open", ["-a", "Finder"], {
      encoding: "utf8",
      maxBuffer: 1024 * 1024,
    });
    if (!openResult.error && openResult.status === 0) {
      return "open -a Finder";
    }

    const scriptResult = spawnSync("/usr/bin/osascript", ["-e", 'tell application "Finder" to activate'], {
      encoding: "utf8",
      maxBuffer: 1024 * 1024,
    });
    if (scriptResult.error) throw scriptResult.error;
    if (scriptResult.status !== 0) {
      throw new Error(
        `Could not activate Finder before Cursor submit: ${scriptResult.stderr || scriptResult.stdout || openResult.stderr || openResult.stdout}`,
      );
    }
    return "osascript Finder activate";
  };

  await send("Runtime.enable");
  await send("Page.enable");
  await send("Emulation.setDeviceMetricsOverride", {
    width,
    height,
    deviceScaleFactor: 2,
    mobile: true,
  });

  await waitFor("auth screen", `return document.body.innerText.includes("Open your agents") || document.body.innerText.includes("Your Macs");`);
  if ((await bodyText()).includes("Open your agents")) {
    if ((await bodyText()).includes("Continue with email instead")) {
      await clickButton("Continue with email instead");
    }
    await fillInput('input[type="email"]', email);
    await clickButton("Continue with email");
    await fillInput('input[type="password"]', password);
    await clickLastButton("Sign in");
  }

  await waitFor("host screen", `return document.body.innerText.includes("Your Macs");`, 45_000);
  const requesterDeviceId = await evaluate(`new Promise((resolve, reject) => {
    const open = indexedDB.open("keyval-store");
    open.onerror = () => reject(new Error("Could not open browser key database."));
    open.onsuccess = () => {
      const db = open.result;
      const tx = db.transaction("keyval", "readonly");
      const req = tx.objectStore("keyval").get("gt.phone.keypair");
      req.onerror = () => reject(new Error("Could not read browser device key."));
      req.onsuccess = () => resolve(req.result && req.result.deviceId ? req.result.deviceId : null);
    };
  })`);
  if (!requesterDeviceId) {
    throw new Error("Browser requester device id was not available after sign-in.");
  }

  const claimResponse = await fetch(`${apiBase}/account/claim-host-code`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${accessToken}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ code: linkCode, requesterDeviceId }),
  });
  if (!claimResponse.ok) {
    const payload = await claimResponse.json().catch(() => ({}));
    const reason = payload.error || payload.msg || "unknown error";
    throw new Error(`claim host code failed with ${claimResponse.status}: ${reason}`);
  }

  await waitFor(
    "claimed host in account API",
    `return fetch(${JSON.stringify(`${apiBase}/account/hosts`)} + "?" + new URLSearchParams({ device_id: ${JSON.stringify(requesterDeviceId)} }).toString(), {
      headers: { authorization: "Bearer " + ${JSON.stringify(accessToken)} },
    }).then(async (response) => {
      if (!response.ok) return false;
      const payload = await response.json();
      return Array.isArray(payload.hosts) && payload.hosts.some((host) =>
        host.deviceId === ${JSON.stringify(hostDeviceId)} &&
        host.label === ${JSON.stringify(hostLabel)} &&
        host.trusted === true &&
        host.online === true
      );
    }).catch(() => false);`,
    60_000,
  );

  await clickButton("Refresh", 20_000);
  await waitFor("linked host visible", `return document.body.innerText.includes(${JSON.stringify(hostLabel)});`, 45_000);
  await clickHostButton(hostLabel, ["Open"], 60_000);
  await waitFor("workspace", `return document.body.innerText.includes("Coding apps") || document.body.innerText.includes("Cursor");`, 45_000);
  await clickButton("Cursor", 30_000);
  let cursorReady = false;
  let cursorReadyError = null;
  for (let attempt = 0; attempt < 3 && !cursorReady; attempt += 1) {
    const text = await bodyText();
    if (text.includes("Mac offline") || text.includes("Connection issue")) {
      await clickButton("Retry connection", 20_000).catch(() => {});
      await sleep(2_000);
    }
    try {
      await waitFor("Cursor start, target switcher, or composer", cursorReadyPredicate, attempt === 0 ? 45_000 : 30_000);
      cursorReady = true;
    } catch (error) {
      cursorReadyError = error;
    }
  }
  if (!cursorReady) {
    throw cursorReadyError || new Error("Cursor hosted surface did not become ready.");
  }

  const readyTargets = await targetButtonsSnapshot();
  if (!(await visibleCursorComposer()) && !(targetSwitchOnly && readyTargets.count >= 2)) {
    await clickAnyButton(["Start", "Open on Mac", "Retry"], 30_000);
    observed.cursorStartedFromWeb = true;
    await waitFor("Cursor composer", cursorReadyPredicate, 60_000);
  } else {
    observed.cursorStartedFromWeb = true;
  }

  if (targetSwitchOnly) {
    await waitFor(
      "Cursor target switcher",
      `const visible = (button) => {
        const rect = button.getBoundingClientRect();
        const style = window.getComputedStyle(button);
        return rect.width > 0 &&
          rect.height > 0 &&
          style.display !== "none" &&
          style.visibility !== "hidden" &&
          style.pointerEvents !== "none";
      };
      const buttons = Array.from(document.querySelectorAll("button")).filter((button) => {
        const label = button.getAttribute("aria-label") || "";
        return visible(button) && (label.startsWith("Switch to ") || label.startsWith("Current session: "));
      });
      return buttons.length >= 2 &&
        buttons.some((button) => (button.getAttribute("aria-label") || "").startsWith("Switch to "));`,
      60_000,
    );
    const beforeTargets = await targetButtonsSnapshot();
    observed.targetButtonCountBefore = beforeTargets.count;
    if (beforeTargets.count < 2 || beforeTargets.switchCount < 1) {
      throw new Error(
        `Cursor target-switch smoke needs at least two visible targets and one switchable target; count=${beforeTargets.count}, switchable=${beforeTargets.switchCount}`,
      );
    }
    observed.targetSwitchCandidateFound = true;
    await clickFirstSwitchableTarget(20_000);
    observed.targetSwitchRequested = true;
    await waitFor(
      "Cursor target selected",
      `return Array.from(document.querySelectorAll("button")).some((button) =>
        (button.getAttribute("aria-label") || "").startsWith("Current session: ") &&
        button.getAttribute("aria-pressed") === "true"
      );`,
      30_000,
    );
    observed.targetSwitchSelected = true;
    await waitFor(
      "Cursor target switching status",
      `return /opening\\s+/i.test(document.body.innerText) || Boolean(document.querySelector('textarea[placeholder*="prompt"]'));`,
      20_000,
    );
    observed.targetSwitchingStateSeen = true;
    const afterTargets = await targetButtonsSnapshot();
    observed.targetButtonCountAfter = afterTargets.count;
    const capture = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
    await fs.writeFile(screenshotPath, Buffer.from(capture.result.data, "base64"));
    const artifact = await writeArtifact();
    if (!artifact.ok) {
      throw new Error("Cursor hosted Chrome target-switch smoke produced partial evidence; see artifact.");
    }
    console.log("Result: passed; hosted rendered Chrome Cursor target switching verified without prompt submission.");
    console.log(`Artifact: ${artifactPath}`);
    console.log(`Screenshot: ${screenshotPath}`);
  } else {
    activateCursorForPreflight();
    await sleep(1_000);
    await verifyAllowedCursorModelSettings();
    if (preflightOnly) {
      const capture = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
      await fs.writeFile(screenshotPath, Buffer.from(capture.result.data, "base64"));
      const artifact = await writeArtifact();
      if (!artifact.ok) {
        throw new Error("Cursor hosted Chrome model/settings preflight produced partial evidence; see artifact.");
      }
      console.log("Result: passed; hosted rendered Chrome Cursor model/settings preflight verified without prompt submission.");
      console.log(`Artifact: ${artifactPath}`);
      console.log(`Screenshot: ${screenshotPath}`);
    } else {
      if (backgroundBeforeSubmit) {
        try {
          const beforeProbe = runCursorProbe();
          observed.cursorWindowAvailableBeforeBackground = beforeProbe.windowAvailable === true;
          observed.cursorBackgroundMethod = backgroundCursor();
          observed.cursorBackgroundedBeforeSubmit = true;
          await sleep(750);
        } catch (error) {
          observed.cursorBackgroundAttemptError = error instanceof Error ? error.message : String(error);
          throw error;
        }
      }

      await fillInput("textarea", prompt);
      await clickButtonByAria("Send", 20_000);
      observed.promptSentFromWeb = true;

      const probeDeadline = Date.now() + Number(process.env.GT_CURSOR_HOSTED_RESPONSE_WAIT_MS || "90000");
      let latestProbe = null;
      while (Date.now() < probeDeadline) {
        latestProbe = runCursorProbe();
        observed.cursorWindowAvailable = latestProbe.windowAvailable === true;
        observed.markerOccurrences = latestProbe.markerOccurrences || 0;
        observed.markerSeenAsPromptAndResponse = latestProbe.markerSeenAsPromptAndResponse === true;
        observed.modelSettingsRecorded = latestProbe.modelSettingsRecorded === true;
        observed.modelSettings = latestProbe.modelSettings || observed.modelSettings;
        if (observed.markerSeenAsPromptAndResponse && observed.modelSettingsRecorded) break;
        await sleep(1_000);
      }

      const capture = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
      await fs.writeFile(screenshotPath, Buffer.from(capture.result.data, "base64"));
      const artifact = await writeArtifact();
      if (!artifact.ok) {
        throw new Error(
          `Cursor hosted Chrome smoke did not satisfy assertions. markerOccurrences=${observed.markerOccurrences}, modelSettingsRecorded=${observed.modelSettingsRecorded}`,
        );
      }
      console.log("Result: passed; hosted rendered Chrome Cursor start, prompt submit, response marker, and visible model/settings verified.");
      console.log(`Artifact: ${artifactPath}`);
      console.log(`Screenshot: ${screenshotPath}`);
    }
  }
} catch (error) {
  const capture = sendCommandForCleanup
    ? await sendCommandForCleanup("Page.captureScreenshot", { format: "png", captureBeyondViewport: true }).catch(() => null)
    : null;
  if (capture?.result?.data) {
    await fs.writeFile(screenshotPath, Buffer.from(capture.result.data, "base64"));
  }
  const artifact = await writeArtifact(error);
  console.error(`Result: failed; ${error instanceof Error ? error.message : String(error)}`);
  console.error(`Artifact: ${artifactPath}`);
  console.error(`Screenshot: ${screenshotPath}`);
  process.exitCode = 1;
} finally {
  await cleanup();
}
NODE
