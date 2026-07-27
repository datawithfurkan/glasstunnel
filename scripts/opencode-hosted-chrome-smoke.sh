#!/usr/bin/env bash
# Verify OpenCode through the hosted PWA rendered in Chrome's mobile viewport.
#
# This uses the same disposable smoke-account and isolated local host harness
# pattern as the Terminal hosted smoke, but targets the direct OpenCode app
# surface: link host, start OpenCode, exercise runtime controls, send one
# bounded prompt, request stop, and record what actually happened.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_URL="${GT_OPENCODE_HOSTED_APP_URL:-https://app.glasstunnel.io}"
DEBUG_PORT="${GT_OPENCODE_HOSTED_DEBUG_PORT:-9251}"
WIDTH="${GT_OPENCODE_HOSTED_WIDTH:-390}"
HEIGHT="${GT_OPENCODE_HOSTED_HEIGHT:-844}"
OUT_DIR="${GT_OPENCODE_HOSTED_OUT_DIR:-/tmp/glasstunnel-opencode-hosted}"
CHROME_BIN="${GT_MOBILE_CHROME_BIN:-}"
SESSION_SWITCH="${GT_OPENCODE_HOSTED_SESSION_SWITCH:-0}"
RUNTIME_MODEL="${GT_OPENCODE_HOSTED_MODEL:-opencode/deepseek-v4-flash-free}"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:opencode:hosted-chrome

Loads .env.platform.local and .env.smoke.local, starts an isolated local Mac
host harness, opens the hosted PWA in Chrome's mobile viewport, signs in with
the disposable email account, links the harness host, starts OpenCode, drives
runtime controls, sends one bounded prompt, requests stop, and records JSON plus
screenshot artifacts.

This is rendered hosted Chrome evidence. It can consume a small amount of
OpenCode provider quota. It is not physical-phone or Safari evidence.

Set GT_OPENCODE_HOSTED_EXPECT_MODEL_BLOCKED=1 with GT_OPENCODE_HOSTED_MODEL to
verify that hosted Chrome renders a clear provider/model failure detail instead
of a generic OpenCode run failure.
USAGE
}

if [[ "${1:-}" == "--" ]]; then
  shift
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
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

cd "$ROOT_DIR"
mkdir -p "$OUT_DIR"
run_stamp="$(date +%Y%m%d%H%M%S)"
host_label="${GT_OPENCODE_HOSTED_HOST_LABEL:-OpenCode hosted Chrome $run_stamp}"

host_log="$(mktemp -t glasstunnel-opencode-hosted-host.XXXXXX.log)"
opencode_data_home="$(mktemp -d -t glasstunnel-opencode-hosted-data.XXXXXX)"
seed_default_dir=""
seed_switch_dir=""
host_pid=""
cleanup() {
  local status=$?
  if [[ -n "$host_pid" ]] && kill -0 "$host_pid" 2>/dev/null; then
    kill "$host_pid" 2>/dev/null || true
    wait "$host_pid" 2>/dev/null || true
  fi
  if [[ "$status" -eq 0 || "${GT_OPENCODE_HOSTED_KEEP_DATA_ON_FAILURE:-1}" != "1" ]]; then
    rm -rf "$opencode_data_home"
  else
    echo "Preserved OpenCode smoke data home after failure: $opencode_data_home" >&2
  fi
  [[ -n "$seed_default_dir" ]] && rm -rf "$seed_default_dir"
  [[ -n "$seed_switch_dir" ]] && rm -rf "$seed_switch_dir"
  return "$status"
}
trap cleanup EXIT

seed_default_label=""
seed_switch_label=""
seed_default_marker="GT_OPENCODE_SESSION_DEFAULT_${run_stamp}"
seed_switch_marker="GT_OPENCODE_SESSION_SWITCH_${run_stamp}"
if [[ "$SESSION_SWITCH" == "1" ]]; then
  opencode_bin="${GT_OPENCODE_BIN:-$(command -v opencode || true)}"
  if [[ -z "$opencode_bin" ]]; then
    echo "OpenCode CLI not found. Cannot seed session-switch smoke data." >&2
    exit 1
  fi
  seed_default_dir="$(mktemp -d -t gt-opencode-default.XXXXXX)"
  seed_switch_dir="$(mktemp -d -t gt-opencode-switch.XXXXXX)"
  seed_default_label="$(basename "$seed_default_dir")"
  seed_switch_label="$(basename "$seed_switch_dir")"
  seed_switch_artifact="$OUT_DIR/opencode-hosted-session-switch-seed-${run_stamp}.txt"
  seed_default_artifact="$OUT_DIR/opencode-hosted-session-default-seed-${run_stamp}.txt"

  (
    cd "$seed_switch_dir"
    XDG_DATA_HOME="$opencode_data_home" \
      "$opencode_bin" run --model "$RUNTIME_MODEL" \
        "Do not use tools. Reply with exactly ${seed_switch_marker}."
  ) >"$seed_switch_artifact" 2>&1
  (
    cd "$seed_default_dir"
    XDG_DATA_HOME="$opencode_data_home" \
      "$opencode_bin" run --model "$RUNTIME_MODEL" \
        "Do not use tools. Reply with exactly ${seed_default_marker}."
  ) >"$seed_default_artifact" 2>&1
fi

XDG_DATA_HOME="$opencode_data_home" \
GT_OPENCODE_DB_PATH="$opencode_data_home/opencode/opencode.db" \
GT_OPENCODE_HOSTED_DATA_HOME="$opencode_data_home" \
GLASSTUNNEL_DEV=1 \
GLASSTUNNEL_KEYCHAIN_SUFFIX="${GT_OPENCODE_HOSTED_KEY_SUFFIX:-opencode-hosted-chrome-$run_stamp}" \
GT_TERMINAL_LIVE_HOST_SECONDS="${GT_OPENCODE_HOSTED_HOST_SECONDS:-300}" \
GT_TERMINAL_LIVE_HOST_LABEL="$host_label" \
swift run --package-path apps/host-macos TerminalLiveHostHarness >"$host_log" 2>&1 &
host_pid="$!"

host_device_id=""
link_code=""
deadline=$((SECONDS + 60))
while (( SECONDS < deadline )); do
  if ! kill -0 "$host_pid" 2>/dev/null; then
    echo "OpenCode hosted host harness exited before link code." >&2
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
  echo "Timed out waiting for OpenCode hosted host link code." >&2
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

GT_OPENCODE_HOSTED_CHROME="$CHROME_BIN" \
GT_OPENCODE_HOSTED_APP_URL="$APP_URL" \
GT_OPENCODE_HOSTED_DEBUG_PORT="$DEBUG_PORT" \
GT_OPENCODE_HOSTED_WIDTH="$WIDTH" \
GT_OPENCODE_HOSTED_HEIGHT="$HEIGHT" \
GT_OPENCODE_HOSTED_OUT_DIR="$OUT_DIR" \
GT_OPENCODE_HOSTED_HOST_DEVICE_ID="$host_device_id" \
GT_OPENCODE_HOSTED_HOST_LABEL="$host_label" \
GT_OPENCODE_HOSTED_LINK_CODE="$link_code" \
GT_OPENCODE_HOSTED_EMAIL="$SMOKE_EMAIL" \
GT_OPENCODE_HOSTED_PASSWORD="$SMOKE_PASSWORD" \
GT_OPENCODE_HOSTED_ACCESS_TOKEN="$access_token" \
GT_OPENCODE_HOSTED_SESSION_SWITCH="$SESSION_SWITCH" \
GT_OPENCODE_HOSTED_SESSION_SWITCH_LABEL="$seed_switch_label" \
GT_OPENCODE_HOSTED_SESSION_SWITCH_MARKER="$seed_switch_marker" \
GT_OPENCODE_HOSTED_SESSION_DEFAULT_LABEL="$seed_default_label" \
GT_OPENCODE_HOSTED_SESSION_DEFAULT_MARKER="$seed_default_marker" \
node <<'NODE'
const { spawn } = await import("node:child_process");
const fs = await import("node:fs/promises");
const os = await import("node:os");
const path = await import("node:path");

const chromeBin = process.env.GT_OPENCODE_HOSTED_CHROME;
const appUrl = process.env.GT_OPENCODE_HOSTED_APP_URL.replace(/\/+$/, "");
const debugPort = process.env.GT_OPENCODE_HOSTED_DEBUG_PORT;
const width = Number(process.env.GT_OPENCODE_HOSTED_WIDTH || "390");
const height = Number(process.env.GT_OPENCODE_HOSTED_HEIGHT || "844");
const outDir = process.env.GT_OPENCODE_HOSTED_OUT_DIR || "/tmp/glasstunnel-opencode-hosted";
const hostDeviceId = process.env.GT_OPENCODE_HOSTED_HOST_DEVICE_ID;
const linkCode = process.env.GT_OPENCODE_HOSTED_LINK_CODE;
const email = process.env.GT_OPENCODE_HOSTED_EMAIL;
const password = process.env.GT_OPENCODE_HOSTED_PASSWORD;
const accessToken = process.env.GT_OPENCODE_HOSTED_ACCESS_TOKEN;
const signaling = process.env.GT_TERMINAL_LIVE_SIGNALING_URL || "wss://signaling.glasstunnel.io/signal";
const apiBase = signaling.replace(/^ws/i, "http").replace(/\/signal\/?$/, "");
const hostLabel = process.env.GT_OPENCODE_HOSTED_HOST_LABEL || "OpenCode hosted smoke host";
const startedAt = Date.now();
const marker = `GT_OPENCODE_HOSTED_${startedAt}`;
const recoveryMarker = `GT_OPENCODE_RECOVERY_${startedAt}`;
const runtimeModel = process.env.GT_OPENCODE_HOSTED_MODEL || "opencode/deepseek-v4-flash-free";
const expectedModelBlocked = process.env.GT_OPENCODE_HOSTED_EXPECT_MODEL_BLOCKED === "1";
const expectedFailureDetails = (process.env.GT_OPENCODE_HOSTED_EXPECT_STATUS_DETAIL ||
  "Provider/model blocked by account, billing, quota, or authorization.|Provider/model is disabled for this account.|Provider/model is not available for this account.")
  .split("|")
  .map((detail) => detail.trim())
  .filter(Boolean);
const genericFailureText = process.env.GT_OPENCODE_HOSTED_GENERIC_FAILURE_TEXT || "OpenCode prompt failed with exit code";
const sessionSwitchEnabled = process.env.GT_OPENCODE_HOSTED_SESSION_SWITCH === "1";
const sessionSwitchLabel = process.env.GT_OPENCODE_HOSTED_SESSION_SWITCH_LABEL || "";
const sessionSwitchMarker = process.env.GT_OPENCODE_HOSTED_SESSION_SWITCH_MARKER || "";
const sessionDefaultLabel = process.env.GT_OPENCODE_HOSTED_SESSION_DEFAULT_LABEL || "";
const sessionDefaultMarker = process.env.GT_OPENCODE_HOSTED_SESSION_DEFAULT_MARKER || "";
const prompt = process.env.GT_OPENCODE_HOSTED_PROMPT || `Do not use tools. Reply first with exactly ${marker} on its own line. Then write numbered harmless filler lines, one per line, starting at 1 and keep going until stopped.`;
const recoveryPrompt = process.env.GT_OPENCODE_HOSTED_RECOVERY_PROMPT || `Do not use tools. Reply with exactly ${recoveryMarker}.`;
const profile = await fs.mkdtemp(path.join(os.tmpdir(), "gt-opencode-hosted-chrome."));
const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
const screenshotPath = path.join(outDir, `chrome-mobile-opencode-hosted-${timestamp}.png`);
const artifactPath = path.join(outDir, `opencode-hosted-chrome-${timestamp}.json`);
const observed = {
  ok: false,
  appUrl,
  hostDeviceId,
  hostLabel,
  marker,
  recoveryMarker,
  opencodeVisible: false,
  started: false,
  runtimeControlsVisible: false,
  runtimeInitialModel: null,
  runtimeAppliedModel: runtimeModel,
  runtimeModelApplied: false,
  expectedModelBlocked,
  expectedFailureDetails,
  failureDetail: null,
  failureDetailVisible: false,
  genericFailureText,
  genericFailureVisible: false,
  promptSubmitted: false,
  workingObserved: false,
  stopRequested: false,
  doneOrStoppedObserved: false,
  composerRecoveredAfterStop: false,
  runtimeModelRecoveredAfterStop: false,
  recoveryPromptSubmitted: false,
  recoveryMarkerSeen: false,
  recoveryDoneObserved: false,
  markerSeen: false,
  sessionSwitchEnabled,
  sessionDefaultLabel: sessionSwitchEnabled ? sessionDefaultLabel : null,
  sessionSwitchLabel: sessionSwitchEnabled ? sessionSwitchLabel : null,
  sessionDefaultMarker: sessionSwitchEnabled ? sessionDefaultMarker : null,
  sessionSwitchMarker: sessionSwitchEnabled ? sessionSwitchMarker : null,
  sessionTargetsVisible: !sessionSwitchEnabled,
  sessionSwitchRequested: !sessionSwitchEnabled,
  sessionSwitchSelected: !sessionSwitchEnabled,
  sessionSwitchHistoryVisible: !sessionSwitchEnabled,
  staleStartupStatusVisible: false,
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
  { stdio: "ignore" },
);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function cleanup() {
  chrome.kill("SIGTERM");
  await fs.rm(profile, { recursive: true, force: true });
}

async function writeArtifact(error) {
  const sessionSwitchOk =
    !sessionSwitchEnabled ||
    (observed.sessionTargetsVisible &&
      observed.sessionSwitchRequested &&
      observed.sessionSwitchSelected &&
      observed.sessionSwitchHistoryVisible &&
      !observed.staleStartupStatusVisible);
  const promptFlowOk =
    sessionSwitchEnabled ||
    (expectedModelBlocked
      ? (observed.promptSubmitted &&
        observed.failureDetailVisible &&
        !observed.genericFailureVisible)
      : (observed.promptSubmitted &&
        observed.stopRequested &&
        observed.composerRecoveredAfterStop &&
        observed.runtimeModelRecoveredAfterStop &&
        observed.recoveryPromptSubmitted &&
        observed.recoveryMarkerSeen &&
        observed.recoveryDoneObserved &&
        observed.doneOrStoppedObserved));
  const payload = {
    ...observed,
    ok: !error &&
      observed.opencodeVisible &&
      observed.started &&
      observed.runtimeControlsVisible &&
      observed.runtimeModelApplied &&
      sessionSwitchOk &&
      promptFlowOk,
    error: error ? String(error.message || error) : undefined,
  };
  await fs.writeFile(artifactPath, `${JSON.stringify(payload, null, 2)}\n`);
  return payload;
}

try {
  if (sessionSwitchEnabled && expectedModelBlocked) {
    throw new Error("Blocked-model rendering smoke cannot run together with session-switch smoke.");
  }

  for (let i = 0; i < 80; i += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${debugPort}/json/version`);
      if (response.ok) break;
    } catch {
      // Retry until Chrome exposes the debugging endpoint.
    }
    await sleep(100);
  }

  const query = new URLSearchParams({ app: "opencode", opencodeHostedSmoke: String(startedAt) });
  const targetUrl = `${appUrl}/?${query.toString()}`;
  const tab = await fetch(`http://127.0.0.1:${debugPort}/json/new?${encodeURIComponent(targetUrl)}`, {
    method: "PUT",
  }).then((response) => response.json());
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
    if (response.error) throw new Error(response.error.message || "Chrome evaluation protocol error");
    if (!response.result) throw new Error(`Chrome evaluation returned no result: ${JSON.stringify(response).slice(0, 300)}`);
    if (response.result.exceptionDetails) throw new Error(response.result.exceptionDetails.text || "Chrome evaluation failed");
    return response.result.result.value;
  };

  const bodyText = () => evaluate(`document.body.innerText`);
  const markerVisibleAfterPromptPredicate = (markerValue) => `
    const text = document.body.innerText;
    return text.split(${JSON.stringify(markerValue)}).length - 1 >= 2;
  `;
  const visibleButtonByAriaPredicate = (ariaLabel) => `
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
      (button.getAttribute("aria-label") === ${JSON.stringify(ariaLabel)} || button.title === ${JSON.stringify(ariaLabel)}) &&
      !button.disabled &&
      visible(button)
    );
  `;
  const waitFor = async (label, predicateSource, timeoutMs = 45_000) => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const result = await evaluate(`(() => { ${predicateSource} })()`);
      if (result) return result;
      await sleep(250);
    }
    const text = await bodyText().catch(() => "");
    throw new Error(`Timed out waiting for ${label}. Visible text: ${String(text).slice(0, 900)}`);
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

  const clickButton = async (label, timeoutMs = 20_000) => {
    const matcher = `button.innerText.trim() === ${JSON.stringify(label)}`;
    await waitFor(
      `button ${label}`,
      visibleButtonPredicate(matcher),
      timeoutMs,
    );
    const clicked = await evaluate(`(() => { ${visibleButtonClickSource(matcher)} })()`);
    if (!clicked) throw new Error(`Could not click button ${label}`);
  };

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
    await waitFor(`host ${hostName} button ${labels.join(", ")}`, `return Boolean((() => { ${candidateSource} })());`, timeoutMs);
    const clicked = await evaluate(`(() => {
      const button = (() => { ${candidateSource} })();
      if (!button) return false;
      button.click();
      return true;
    })()`);
    if (!clicked) throw new Error(`Could not click host ${hostName} button: ${labels.join(", ")}`);
  };

  const clickButtonByAria = async (label, timeoutMs = 20_000) => {
    const matcher = `(button.getAttribute("aria-label") === ${JSON.stringify(label)} || button.title === ${JSON.stringify(label)})`;
    await waitFor(
      `button aria-label ${label}`,
      visibleButtonPredicate(matcher),
      timeoutMs,
    );
    const clicked = await evaluate(`(() => { ${visibleButtonClickSource(matcher)} })()`);
    if (!clicked) throw new Error(`Could not click ${label}`);
  };

  const fillVisibleTextarea = async (value) => {
    const ok = await evaluate(`(() => {
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        const style = window.getComputedStyle(element);
        return rect.width > 0 &&
          rect.height > 0 &&
          style.display !== "none" &&
          style.visibility !== "hidden" &&
          style.pointerEvents !== "none";
      };
      const input = Array.from(document.querySelectorAll("textarea")).find((candidate) =>
        !candidate.disabled && visible(candidate)
      );
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
    if (!ok) throw new Error("Could not fill visible composer textarea");
  };

  const clickComposerPrimaryAction = async (label, timeoutMs = 20_000) => {
    const encodedLabel = JSON.stringify(label);
    const predicate = `
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        const style = window.getComputedStyle(element);
        return rect.width > 0 &&
          rect.height > 0 &&
          style.display !== "none" &&
          style.visibility !== "hidden" &&
          style.pointerEvents !== "none";
      };
      const textarea = Array.from(document.querySelectorAll("textarea")).find((candidate) =>
        !candidate.disabled && visible(candidate)
      );
      if (!textarea) return false;
      const container = textarea.closest("footer") || textarea.closest("form") || textarea.parentElement;
      if (!container) return false;
      return Array.from(container.querySelectorAll("button")).some((button) =>
        (button.getAttribute("aria-label") === ${encodedLabel} || button.title === ${encodedLabel}) &&
        !button.disabled &&
        visible(button)
      );
    `;
    await waitFor(`composer ${label} button`, predicate, timeoutMs);
    const clicked = await evaluate(`(() => {
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        const style = window.getComputedStyle(element);
        return rect.width > 0 &&
          rect.height > 0 &&
          style.display !== "none" &&
          style.visibility !== "hidden" &&
          style.pointerEvents !== "none";
      };
      const textarea = Array.from(document.querySelectorAll("textarea")).find((candidate) =>
        !candidate.disabled && visible(candidate)
      );
      if (!textarea) return false;
      const container = textarea.closest("footer") || textarea.closest("form") || textarea.parentElement;
      if (!container) return false;
      const button = Array.from(container.querySelectorAll("button")).find((candidate) =>
        (candidate.getAttribute("aria-label") === ${encodedLabel} || candidate.title === ${encodedLabel}) &&
        !candidate.disabled &&
        visible(candidate)
      );
      if (!button) return false;
      button.click();
      return true;
    })()`);
    if (!clicked) throw new Error(`Could not click composer ${label}`);
  };

  const submitComposerPrompt = async (value, label) => {
    const encodedValue = JSON.stringify(value);
    await waitFor(`${label} composer enabled`, `
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        const style = window.getComputedStyle(element);
        return rect.width > 0 &&
          rect.height > 0 &&
          style.display !== "none" &&
          style.visibility !== "hidden" &&
          style.pointerEvents !== "none";
      };
      const textarea = Array.from(document.querySelectorAll("textarea")).find((candidate) =>
        !candidate.disabled && visible(candidate)
      );
      return Boolean(textarea);
    `, 60_000);
    await fillVisibleTextarea(value);
    await waitFor(`${label} composer filled`, `
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        const style = window.getComputedStyle(element);
        return rect.width > 0 &&
          rect.height > 0 &&
          style.display !== "none" &&
          style.visibility !== "hidden" &&
          style.pointerEvents !== "none";
      };
      return Array.from(document.querySelectorAll("textarea")).some((candidate) =>
        !candidate.disabled && visible(candidate) && candidate.value === ${encodedValue}
      );
    `, 10_000);
    await clickComposerPrimaryAction("Send prompt", 20_000);
    await waitFor(`${label} composer submitted`, `
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        const style = window.getComputedStyle(element);
        return rect.width > 0 &&
          rect.height > 0 &&
          style.display !== "none" &&
          style.visibility !== "hidden" &&
          style.pointerEvents !== "none";
      };
      return !Array.from(document.querySelectorAll("textarea")).some((candidate) =>
        visible(candidate) && candidate.value === ${encodedValue}
      );
    `, Number(process.env.GT_OPENCODE_HOSTED_SUBMIT_WAIT_MS || "10000"));
  };

  const clickSubmitButton = async (label, timeoutMs = 20_000) => {
    await waitFor(
      `submit button ${label}`,
      `return Array.from(document.querySelectorAll('button[type="submit"]')).some((button) => button.innerText.trim() === ${JSON.stringify(label)} && !button.disabled);`,
      timeoutMs,
    );
    const clicked = await evaluate(`(() => {
      const button = Array.from(document.querySelectorAll('button[type="submit"]')).find((candidate) => candidate.innerText.trim() === ${JSON.stringify(label)} && !candidate.disabled);
      if (!button) return false;
      button.click();
      return true;
    })()`);
    if (!clicked) throw new Error(`Could not click submit button ${label}`);
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

  const selectValue = async (selector, value) => {
    const ok = await evaluate(`(() => {
      const select = document.querySelector(${JSON.stringify(selector)});
      if (!select) return false;
      select.value = ${JSON.stringify(value)};
      select.dispatchEvent(new Event("input", { bubbles: true }));
      select.dispatchEvent(new Event("change", { bubbles: true }));
      return true;
    })()`);
    if (!ok) throw new Error(`Could not select ${value} for ${selector}`);
  };

  await send("Runtime.enable");
  await send("Page.enable");
  await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 2, mobile: true });

  await waitFor("auth screen", `return document.body.innerText.includes("Open your agents") || document.body.innerText.includes("Your Macs");`);
  if ((await bodyText()).includes("Open your agents")) {
    if ((await bodyText()).includes("Continue with email instead")) {
      await clickButton("Continue with email instead");
    }
    await fillInput('input[type="email"]', email);
    await clickButton("Continue with email");
    await fillInput('input[type="password"]', password);
    await clickSubmitButton("Sign in");
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
  if (!requesterDeviceId) throw new Error("Browser requester device id was not available after sign-in.");

  const claimResponse = await fetch(`${apiBase}/account/claim-host-code`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
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

  await waitFor("workspace", `return document.body.innerText.includes("Coding apps") || document.body.innerText.includes("OpenCode");`, 45_000);
  const openCodeSurfaceReady = await waitFor(
    "direct OpenCode surface",
    `const text = document.body.innerText;
     return text.includes("Start OpenCode on this Mac") ||
       text.includes("OpenCode stopped") ||
       text.includes("provider/model") ||
       text.includes("OpenCode is ready") ||
       text.includes("Ask anything");`,
    15_000,
  ).then(() => true).catch(() => false);
  if (!openCodeSurfaceReady) {
    await clickButton("OpenCode", 30_000);
  }
  await waitFor("OpenCode surface", `return document.body.innerText.includes("OpenCode");`, 45_000);
  observed.opencodeVisible = true;

  const openCodeStartedPredicate =
    `const text = document.body.innerText; return text.includes("OpenCode") && (text.includes("Model") || text.includes("provider/model") || text.includes("Send a prompt") || text.includes("WORKING") || text.includes("READY") || text.includes("Ask anything"));`;
  let started = false;
  let startError = null;
  for (let attempt = 0; attempt < 3 && !started; attempt += 1) {
    const text = await bodyText();
    if (text.includes("Start OpenCode on this Mac") || text.includes("OpenCode stopped")) {
      await clickButton("Start", 30_000);
    }
    try {
      await waitFor("OpenCode started or controls visible", openCodeStartedPredicate, attempt === 0 ? 45_000 : 30_000);
      started = true;
    } catch (error) {
      startError = error;
    }
  }
  if (!started) {
    throw startError || new Error("OpenCode did not start.");
  }
  observed.started = true;

  if (sessionSwitchEnabled) {
    if (!sessionSwitchLabel || !sessionSwitchMarker) {
      throw new Error("Session-switch smoke was enabled without seeded session metadata.");
    }
    await waitFor(
      "OpenCode session switch target",
      visibleButtonByAriaPredicate(`Switch to ${sessionSwitchLabel}`),
      60_000,
    );
    observed.sessionTargetsVisible = true;
    await clickButtonByAria(`Switch to ${sessionSwitchLabel}`, 20_000);
    observed.sessionSwitchRequested = true;
    await waitFor(
      "OpenCode switched session selected",
      `return Array.from(document.querySelectorAll("button")).some((button) =>
        button.getAttribute("aria-label") === ${JSON.stringify(`Current session: ${sessionSwitchLabel}`)} &&
        button.getAttribute("aria-pressed") === "true"
      );`,
      60_000,
    );
    observed.sessionSwitchSelected = true;
    await waitFor(
      "OpenCode switched session history",
      `return document.body.innerText.includes(${JSON.stringify(sessionSwitchMarker)});`,
      60_000,
    );
    observed.sessionSwitchHistoryVisible = true;
  }

  const runtime = await waitFor(
    "OpenCode runtime controls",
    `const model = document.querySelector('input[placeholder="provider/model"]');
     const apply = Array.from(document.querySelectorAll("button")).find((button) => button.innerText.trim() === "Apply");
     if (!model || !apply) return false;
     return {
       model: model.value || null,
       placeholder: model.placeholder || null,
       canApply: !apply.disabled,
     };`,
    60_000,
  );
  observed.runtimeControlsVisible = true;
  observed.runtimeInitialModel = runtime.model;

  await fillInput('input[placeholder="provider/model"]', runtimeModel);
  await clickButton("Apply", 20_000);
  await waitFor(
    "OpenCode provider/model applied",
    `const input = document.querySelector('input[placeholder="provider/model"]'); return input && input.value === ${JSON.stringify(runtimeModel)};`,
    30_000,
  );
  observed.runtimeModelApplied = true;
  await sleep(3_000);

  if (sessionSwitchEnabled) {
    await waitFor(
      "OpenCode switched session still selected after runtime apply",
      `return Array.from(document.querySelectorAll("button")).some((button) =>
        button.getAttribute("aria-label") === ${JSON.stringify(`Current session: ${sessionSwitchLabel}`)} &&
        button.getAttribute("aria-pressed") === "true"
      );`,
      30_000,
    );
    await waitFor(
      "OpenCode switched session history still visible after runtime apply",
      `return document.body.innerText.includes(${JSON.stringify(sessionSwitchMarker)});`,
      30_000,
    );
    observed.staleStartupStatusVisible = await evaluate(`(() => {
      const text = document.body.innerText;
      return text.includes("Opening OpenCode on this Mac.") ||
        text.includes("Starting OpenCode on this Mac.");
    })()`).catch(() => false);
    const capture = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
    await fs.writeFile(screenshotPath, Buffer.from(capture.result.data, "base64"));
    const artifact = await writeArtifact();
    if (!artifact.ok) {
      throw new Error("OpenCode hosted Chrome session-switch smoke produced partial evidence; see artifact.");
    }
    console.log("Result: passed; hosted rendered Chrome OpenCode session switching verified.");
    console.log(`Artifact: ${artifactPath}`);
    console.log(`Screenshot: ${screenshotPath}`);
    await cleanup();
    process.exit(0);
  } else {
  await submitComposerPrompt(prompt, "initial OpenCode prompt");
  observed.promptSubmitted = true;

  if (expectedModelBlocked) {
    const failureDetail = await waitFor(
      "OpenCode blocked provider/model detail",
      `const text = document.body.innerText;
       return ${JSON.stringify(expectedFailureDetails)}.find((detail) => text.includes(detail)) || false;`,
      Number(process.env.GT_OPENCODE_HOSTED_FAILURE_WAIT_MS || "90000"),
    );
    observed.failureDetail = failureDetail;
    observed.failureDetailVisible = true;
    observed.genericFailureVisible = await evaluate(
      `document.body.innerText.includes(${JSON.stringify(genericFailureText)})`,
    ).catch(() => false);

    const capture = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
    await fs.writeFile(screenshotPath, Buffer.from(capture.result.data, "base64"));
    const artifact = await writeArtifact();
    if (!artifact.ok) {
      throw new Error("OpenCode hosted Chrome blocked-model smoke produced partial evidence; see artifact.");
    }
    console.log(`Result: passed; hosted rendered OpenCode blocked-model detail: ${failureDetail}`);
    console.log(`Artifact: ${artifactPath}`);
    console.log(`Screenshot: ${screenshotPath}`);
    await cleanup();
    process.exit(0);
  } else {
  try {
    await waitFor("OpenCode working state", `return document.body.innerText.toLowerCase().includes("working") || document.body.innerText.toLowerCase().includes("running");`, 25_000);
    observed.workingObserved = true;
  } catch {
    // Prompt may complete quickly or the TUI may not expose a clean working label.
  }

  try {
    await waitFor(
      "OpenCode assistant prompt marker",
      markerVisibleAfterPromptPredicate(marker),
      Number(process.env.GT_OPENCODE_HOSTED_MARKER_WAIT_MS || "8000"),
    );
    observed.markerSeen = true;
  } catch {
    // Keep the artifact as diagnostic evidence if the model did not return the marker.
  }

  await clickComposerPrimaryAction("Stop response", 30_000);
  observed.stopRequested = true;
  await sleep(Number(process.env.GT_OPENCODE_HOSTED_STOP_WAIT_MS || "5000"));

  try {
    await waitFor(
      "OpenCode done or stopped state",
      `const text = document.body.innerText.toLowerCase(); return text.includes("done") || text.includes("ready") || text.includes("stopped") || text.includes("stop requested") || text.includes("interrupted") || text.includes("prompt returned");`,
      30_000,
    );
    observed.doneOrStoppedObserved = true;
  } catch {
    // Keep the artifact as diagnostic evidence if stop/done is still not visible.
  }

  const recovered = await waitFor(
    "OpenCode usable after stop",
    `const textarea = document.querySelector("textarea");
     const model = document.querySelector('input[placeholder="provider/model"]');
     if (!textarea || textarea.disabled || !model || model.value !== ${JSON.stringify(runtimeModel)}) return false;
     return {
       composerRecovered: true,
       modelRecovered: true,
     };`,
    60_000,
  );
  observed.composerRecoveredAfterStop = recovered.composerRecovered === true;
  observed.runtimeModelRecoveredAfterStop = recovered.modelRecovered === true;

  await submitComposerPrompt(recoveryPrompt, "OpenCode recovery prompt");
  observed.recoveryPromptSubmitted = true;

  await waitFor(
    "OpenCode recovery assistant marker",
    markerVisibleAfterPromptPredicate(recoveryMarker),
    Number(process.env.GT_OPENCODE_HOSTED_RECOVERY_MARKER_WAIT_MS || "90000"),
  );
  observed.recoveryMarkerSeen = true;

  await waitFor(
    "OpenCode recovery prompt visibly idle",
    `const text = document.body.innerText;
     const lower = text.toLowerCase();
     const compactStatusText = lower.replace(/\\s+/g, "");
     const input = document.querySelector("textarea");
     const stopButtonVisible = Array.from(document.querySelectorAll("button")).some((button) => {
       const rect = button.getBoundingClientRect();
       const style = window.getComputedStyle(button);
       return (button.getAttribute("aria-label") === "Stop response" || button.title === "Stop response") &&
         !button.disabled &&
         rect.width > 0 &&
         rect.height > 0 &&
         style.display !== "none" &&
         style.visibility !== "hidden" &&
         style.pointerEvents !== "none";
     });
     return input &&
       !input.disabled &&
       (input.placeholder || "").toLowerCase().includes("prompt") &&
       !stopButtonVisible &&
       (compactStatusText.includes("done") || compactStatusText.includes("ready") || lower.includes("stopped") || lower.includes("prompt returned"));`,
    60_000,
  );
  observed.recoveryDoneObserved = true;

  if (!observed.markerSeen) {
    observed.markerSeen = await evaluate(`(() => { ${markerVisibleAfterPromptPredicate(marker)} })()`).catch(() => false);
  }
  if (!observed.recoveryMarkerSeen) {
    observed.recoveryMarkerSeen = await evaluate(`(() => { ${markerVisibleAfterPromptPredicate(recoveryMarker)} })()`).catch(() => false);
  }

  const capture = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
  await fs.writeFile(screenshotPath, Buffer.from(capture.result.data, "base64"));
  const artifact = await writeArtifact();
  if (!artifact.ok) {
    throw new Error("OpenCode hosted Chrome smoke produced partial evidence; see artifact.");
  }
  console.log("Result: passed; hosted rendered Chrome OpenCode start, runtime controls, prompt, stop, and recovery prompt verified.");
  console.log(`Artifact: ${artifactPath}`);
  console.log(`Screenshot: ${screenshotPath}`);
  await cleanup();
  process.exit(0);
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
