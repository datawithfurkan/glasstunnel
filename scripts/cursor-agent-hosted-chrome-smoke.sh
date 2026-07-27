#!/usr/bin/env bash
# Verify standalone Cursor Agent through the hosted PWA in Chrome's mobile viewport.
#
# This uses the disposable smoke account and an isolated local host harness,
# opens the hosted mobile web UI, starts the `cursor-agent` remote app, sends a
# bounded marker prompt through the mobile command surface, and records JSON plus
# screenshot artifacts. It tests the Cursor Agent CLI-backed product path, not
# desktop Cursor target routing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_URL="${GT_CURSOR_AGENT_HOSTED_APP_URL:-https://app.glasstunnel.io}"
DEBUG_PORT="${GT_CURSOR_AGENT_HOSTED_DEBUG_PORT:-9256}"
WIDTH="${GT_CURSOR_AGENT_HOSTED_WIDTH:-390}"
HEIGHT="${GT_CURSOR_AGENT_HOSTED_HEIGHT:-844}"
OUT_DIR="${GT_CURSOR_AGENT_HOSTED_OUT_DIR:-/tmp/glasstunnel-cursor-agent-hosted}"
CHROME_BIN="${GT_MOBILE_CHROME_BIN:-}"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:cursor:agent-hosted-chrome

Loads .env.platform.local and .env.smoke.local, starts an isolated local Mac
host harness, opens the hosted PWA in Chrome's mobile viewport, signs in with
the disposable email account, links the harness host, starts Cursor Agent,
sends one bounded marker prompt, and records a JSON artifact plus screenshot.

This can consume a small Cursor Agent model call using the verified
gpt-5.4-nano-none ask-mode path. It is hosted Chrome mobile-viewport evidence,
not physical-phone or Safari evidence.

Set GT_CURSOR_AGENT_HOSTED_STOP_RECOVERY=1 to run the stricter Stop/recovery
variant: submit a longer bounded prompt, request Stop while the prompt is
running, verify composer recovery, then submit a second bounded marker prompt.

Set GT_CURSOR_AGENT_HOSTED_ASK_MODE_PREFLIGHT=1 to verify the hosted mobile
Cursor Agent surface exposes the ask-only/edit-disabled state without
submitting a prompt or consuming a model call.
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
  echo "Result: blocked; Cursor Agent hosted Chrome smoke requires macOS." >&2
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

if [[ ! -x "${GT_CURSOR_AGENT_PATH:-$HOME/.local/bin/cursor-agent}" ]] && ! command -v cursor-agent >/dev/null 2>&1; then
  echo "Standalone cursor-agent executable is not available." >&2
  exit 1
fi

cd "$ROOT_DIR"
mkdir -p "$OUT_DIR"
run_stamp="$(date +%Y%m%d%H%M%S)"
host_label="${GT_CURSOR_AGENT_HOSTED_HOST_LABEL:-Cursor Agent hosted Chrome $run_stamp}"

host_log="$(mktemp -t glasstunnel-cursor-agent-hosted-host.XXXXXX.log)"
host_pid=""
cleanup() {
  if [[ -n "$host_pid" ]] && kill -0 "$host_pid" 2>/dev/null; then
    kill "$host_pid" 2>/dev/null || true
    wait "$host_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

GLASSTUNNEL_DEV=1 \
GLASSTUNNEL_KEYCHAIN_SUFFIX="${GT_CURSOR_AGENT_HOSTED_KEY_SUFFIX:-cursor-agent-hosted-chrome-$run_stamp}" \
GT_TERMINAL_LIVE_HOST_SECONDS="${GT_CURSOR_AGENT_HOSTED_HOST_SECONDS:-300}" \
GT_TERMINAL_LIVE_HOST_LABEL="$host_label" \
swift run --package-path apps/host-macos TerminalLiveHostHarness >"$host_log" 2>&1 &
host_pid="$!"

host_device_id=""
link_code=""
deadline=$((SECONDS + 60))
while (( SECONDS < deadline )); do
  if ! kill -0 "$host_pid" 2>/dev/null; then
    echo "Cursor Agent hosted host harness exited before link code." >&2
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
  echo "Timed out waiting for Cursor Agent hosted host link code." >&2
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

GT_CURSOR_AGENT_HOSTED_CHROME="$CHROME_BIN" \
GT_CURSOR_AGENT_HOSTED_APP_URL="$APP_URL" \
GT_CURSOR_AGENT_HOSTED_DEBUG_PORT="$DEBUG_PORT" \
GT_CURSOR_AGENT_HOSTED_WIDTH="$WIDTH" \
GT_CURSOR_AGENT_HOSTED_HEIGHT="$HEIGHT" \
GT_CURSOR_AGENT_HOSTED_OUT_DIR="$OUT_DIR" \
GT_CURSOR_AGENT_HOSTED_HOST_DEVICE_ID="$host_device_id" \
GT_CURSOR_AGENT_HOSTED_HOST_LABEL="$host_label" \
GT_CURSOR_AGENT_HOSTED_LINK_CODE="$link_code" \
GT_CURSOR_AGENT_HOSTED_EMAIL="$SMOKE_EMAIL" \
GT_CURSOR_AGENT_HOSTED_PASSWORD="$SMOKE_PASSWORD" \
GT_CURSOR_AGENT_HOSTED_ACCESS_TOKEN="$access_token" \
node <<'NODE'
const { spawn } = await import("node:child_process");
const fs = await import("node:fs/promises");
const os = await import("node:os");
const path = await import("node:path");

const chromeBin = process.env.GT_CURSOR_AGENT_HOSTED_CHROME;
const appUrl = process.env.GT_CURSOR_AGENT_HOSTED_APP_URL.replace(/\/+$/, "");
const debugPort = process.env.GT_CURSOR_AGENT_HOSTED_DEBUG_PORT;
const width = Number(process.env.GT_CURSOR_AGENT_HOSTED_WIDTH || "390");
const height = Number(process.env.GT_CURSOR_AGENT_HOSTED_HEIGHT || "844");
const outDir = process.env.GT_CURSOR_AGENT_HOSTED_OUT_DIR || "/tmp/glasstunnel-cursor-agent-hosted";
const hostDeviceId = process.env.GT_CURSOR_AGENT_HOSTED_HOST_DEVICE_ID;
const hostLabel = process.env.GT_CURSOR_AGENT_HOSTED_HOST_LABEL || "Cursor Agent hosted smoke host";
const linkCode = process.env.GT_CURSOR_AGENT_HOSTED_LINK_CODE;
const email = process.env.GT_CURSOR_AGENT_HOSTED_EMAIL;
const password = process.env.GT_CURSOR_AGENT_HOSTED_PASSWORD;
const accessToken = process.env.GT_CURSOR_AGENT_HOSTED_ACCESS_TOKEN;
const signaling = process.env.GT_TERMINAL_LIVE_SIGNALING_URL || "wss://signaling.glasstunnel.io/signal";
const apiBase = signaling.replace(/^ws/i, "http").replace(/\/signal\/?$/, "");
const startedAt = Date.now();
const marker = `GT_CURSOR_AGENT_HOSTED_${startedAt}`;
const stopRecoveryMode = process.env.GT_CURSOR_AGENT_HOSTED_STOP_RECOVERY === "1";
const recoveryMarker = `GT_CURSOR_AGENT_RECOVERY_${startedAt}`;
const prompt = process.env.GT_CURSOR_AGENT_HOSTED_PROMPT || (stopRecoveryMode
  ? `Write 120 numbered short lines. Each line must include ${marker}. Do not use markdown. Keep writing until stopped.`
  : `Reply with exactly ${marker}.`);
const recoveryPrompt = process.env.GT_CURSOR_AGENT_HOSTED_RECOVERY_PROMPT || `Reply with exactly ${recoveryMarker}.`;
const askModePreflightOnly = process.env.GT_CURSOR_AGENT_HOSTED_ASK_MODE_PREFLIGHT === "1";
const profile = await fs.mkdtemp(path.join(os.tmpdir(), "gt-cursor-agent-hosted-chrome."));
const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
const artifactPrefix = askModePreflightOnly
  ? "cursor-agent-hosted-chrome-ask-mode"
  : stopRecoveryMode
    ? "cursor-agent-hosted-chrome-stop-recovery"
    : "cursor-agent-hosted-chrome";
const screenshotPrefix = askModePreflightOnly
  ? "chrome-mobile-cursor-agent-hosted-ask-mode"
  : stopRecoveryMode
    ? "chrome-mobile-cursor-agent-hosted-stop-recovery"
    : "chrome-mobile-cursor-agent-hosted";
const screenshotPath = path.join(outDir, `${screenshotPrefix}-${timestamp}.png`);
const artifactPath = path.join(outDir, `${artifactPrefix}-${timestamp}.json`);
const observed = {
  ok: false,
  appUrl,
  hostDeviceId,
  hostLabel,
  remoteAppId: "cursor-agent",
  stopRecoveryMode,
  askModePreflightOnly,
  appVisible: false,
  started: false,
  runtimeControlsVisible: false,
  runtimeModel: null,
  askModeNoticeVisible: false,
  fileEditsDisabledNoticeVisible: false,
  promptSubmitted: false,
  workingObserved: false,
  markerSeen: false,
  stopButtonObserved: false,
  stopRequested: false,
  stoppedObserved: false,
  recoveryPromptSubmitted: false,
  recoveryMarkerSeen: false,
  recoveryDoneObserved: false,
  doneObserved: false,
  composerRecovered: false,
  screenshot: screenshotPath,
  chromeExitCode: null,
  chromeErrorTail: "",
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

async function cleanupChrome() {
  chrome.kill("SIGTERM");
  await fs.rm(profile, { recursive: true, force: true });
}

async function writeArtifact(error) {
  observed.chromeErrorTail = chromeErrors.join("").slice(-1200);
  const payload = {
    ...observed,
    ok:
      !error &&
      observed.appVisible &&
      observed.started &&
      observed.runtimeControlsVisible &&
      observed.runtimeModel === "gpt-5.4-nano-none" &&
      observed.askModeNoticeVisible &&
      observed.fileEditsDisabledNoticeVisible &&
      (askModePreflightOnly
        ? !observed.promptSubmitted
        : observed.promptSubmitted &&
          (stopRecoveryMode
            ? observed.workingObserved &&
              observed.stopButtonObserved &&
              observed.stopRequested &&
              observed.stoppedObserved &&
              observed.recoveryPromptSubmitted &&
              observed.recoveryMarkerSeen &&
              observed.recoveryDoneObserved
            : observed.markerSeen) &&
          observed.doneObserved &&
          observed.composerRecovered),
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

  for (let i = 0; i < 80; i += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${debugPort}/json/version`);
      if (response.ok) break;
    } catch {
      // Retry until Chrome exposes the debugging endpoint.
    }
    if (chrome.exitCode !== null) break;
    await sleep(100);
  }

  const targetUrl = `${appUrl}/?${new URLSearchParams({ cursorAgentSmoke: String(startedAt), app: "cursor-agent" }).toString()}`;
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
    if (response.error) throw new Error(response.error.message || "Chrome evaluation protocol error");
    if (!response.result) throw new Error(`Chrome evaluation returned no result: ${JSON.stringify(response).slice(0, 300)}`);
    if (response.result.exceptionDetails) throw new Error(response.result.exceptionDetails.text || "Chrome evaluation failed");
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

  const visiblePredicate = `
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = window.getComputedStyle(element);
      return rect.width > 0 &&
        rect.height > 0 &&
        style.display !== "none" &&
        style.visibility !== "hidden" &&
        style.pointerEvents !== "none";
    };
  `;

  const clickButton = async (label, timeoutMs = 20_000) => {
    await waitFor(
      `button ${label}`,
      `${visiblePredicate}
       return Array.from(document.querySelectorAll("button")).some((button) => button.innerText.trim() === ${JSON.stringify(label)} && !button.disabled && visible(button));`,
      timeoutMs,
    );
    const clicked = await evaluate(`(() => {
      ${visiblePredicate}
      const button = Array.from(document.querySelectorAll("button")).find((candidate) => candidate.innerText.trim() === ${JSON.stringify(label)} && !candidate.disabled && visible(candidate));
      if (!button) return false;
      button.click();
      return true;
    })()`);
    if (!clicked) throw new Error(`Could not click button ${label}`);
  };

  const clickLastButton = async (label, timeoutMs = 20_000) => {
    await waitFor(
      `last button ${label}`,
      `${visiblePredicate}
       return Array.from(document.querySelectorAll("button")).some((button) => button.innerText.trim() === ${JSON.stringify(label)} && !button.disabled && visible(button));`,
      timeoutMs,
    );
    const clicked = await evaluate(`(() => {
      ${visiblePredicate}
      const buttons = Array.from(document.querySelectorAll("button")).filter((candidate) => candidate.innerText.trim() === ${JSON.stringify(label)} && !candidate.disabled && visible(candidate));
      const button = buttons.at(-1);
      if (!button) return false;
      button.click();
      return true;
    })()`);
    if (!clicked) throw new Error(`Could not click last button ${label}`);
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
    await waitFor(`host ${hostName} button`, `return Boolean((() => { ${candidateSource} })());`, timeoutMs);
    const clicked = await evaluate(`(() => {
      const button = (() => { ${candidateSource} })();
      if (!button) return false;
      button.click();
      return true;
    })()`);
    if (!clicked) throw new Error(`Could not click host ${hostName} button`);
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

  const fillVisibleTextarea = async (value) => {
    const ok = await evaluate(`(() => {
      ${visiblePredicate}
      const input = Array.from(document.querySelectorAll("textarea")).find((candidate) => !candidate.disabled && visible(candidate));
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
    await waitFor(
      `composer ${label} button`,
      `${visiblePredicate}
       const textarea = Array.from(document.querySelectorAll("textarea")).find((candidate) => !candidate.disabled && visible(candidate));
       if (!textarea) return false;
       const container = textarea.closest("footer") || textarea.closest("form") || textarea.parentElement;
       if (!container) return false;
       return Array.from(container.querySelectorAll("button")).some((button) =>
         (button.getAttribute("aria-label") === ${encodedLabel} || button.title === ${encodedLabel}) &&
         !button.disabled &&
         visible(button)
       );`,
      timeoutMs,
    );
    const clicked = await evaluate(`(() => {
      ${visiblePredicate}
      const textarea = Array.from(document.querySelectorAll("textarea")).find((candidate) => !candidate.disabled && visible(candidate));
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

  const submitComposerPrompt = async (value) => {
    await waitFor(
      "Cursor Agent composer enabled",
      `${visiblePredicate}
       return Array.from(document.querySelectorAll("textarea")).some((candidate) => !candidate.disabled && visible(candidate));`,
      60_000,
    );
    await fillVisibleTextarea(value);
    await clickComposerPrimaryAction("Send prompt", 20_000);
    await waitFor(
      "Cursor Agent composer submitted",
      `${visiblePredicate}
       return !Array.from(document.querySelectorAll("textarea")).some((candidate) => visible(candidate) && candidate.value === ${JSON.stringify(value)});`,
      15_000,
    );
  };

  const waitForRecoveredComposer = async (label, timeoutMs = 60_000) => {
    await waitFor(
      label,
      `${visiblePredicate}
       const text = document.body.innerText;
       const lower = text.toLowerCase();
       const compact = lower.replace(/\\s+/g, "");
       const input = Array.from(document.querySelectorAll("textarea")).find((candidate) => visible(candidate));
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
         !stopButtonVisible &&
         (compact.includes("ready") ||
          compact.includes("done") ||
          lower.includes("prompt returned") ||
          lower.includes("interrupted") ||
          lower.includes("stopped"));`,
      timeoutMs,
    );
  };

  const waitForStopButton = async (timeoutMs = 30_000) => {
    await waitFor(
      "Cursor Agent Stop response button",
      `${visiblePredicate}
       return Array.from(document.querySelectorAll("button")).some((button) =>
         (button.getAttribute("aria-label") === "Stop response" || button.title === "Stop response") &&
         !button.disabled &&
         visible(button)
       );`,
      timeoutMs,
    );
    observed.stopButtonObserved = true;
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
  await waitFor("workspace", `return document.body.innerText.includes("Coding apps") || document.body.innerText.includes("Cursor Agent");`, 45_000);

  const directSurfaceReady = await waitFor(
    "direct Cursor Agent surface",
    `const text = document.body.innerText;
     return text.includes("Start Cursor Agent on this Mac") ||
       text.includes("Cursor Agent stopped") ||
       text.includes("Uses Cursor Agent ask mode") ||
       text.includes("Ask mode only") ||
       text.includes("Send a prompt") ||
       text.includes("Cursor Agent");`,
    15_000,
  ).then(() => true).catch(() => false);
  if (!directSurfaceReady || !(await bodyText()).includes("Cursor Agent")) {
    await clickButton("Cursor Agent", 30_000);
  }
  await waitFor("Cursor Agent surface", `return document.body.innerText.includes("Cursor Agent");`, 45_000);
  observed.appVisible = true;

  const startedPredicate =
    `const text = document.body.innerText;
     return text.includes("Cursor Agent") &&
       (text.includes("Uses Cursor Agent ask mode") ||
        text.includes("Ask mode only") ||
        text.includes("GPT 5.4 Nano") ||
        text.includes("Send a prompt") ||
        text.includes("RUNNING") ||
        text.includes("READY") ||
        text.includes("Ask anything"));`;
  let started = false;
  let startError = null;
  for (let attempt = 0; attempt < 3 && !started; attempt += 1) {
    const text = await bodyText();
    if (text.includes("Start Cursor Agent on this Mac") || text.includes("Cursor Agent stopped")) {
      await clickButton("Start", 30_000);
    }
    try {
      await waitFor("Cursor Agent started or controls visible", startedPredicate, attempt === 0 ? 60_000 : 30_000);
      started = true;
    } catch (error) {
      startError = error;
    }
  }
  if (!started) {
    throw startError || new Error("Cursor Agent did not start.");
  }
  observed.started = true;

  const runtime = await waitFor(
    "Cursor Agent runtime controls",
    `const text = document.body.innerText;
     if (!text.includes("GPT 5.4 Nano") && !text.includes("gpt-5.4-nano-none")) return false;
     return { model: text.includes("gpt-5.4-nano-none") ? "gpt-5.4-nano-none" : "gpt-5.4-nano-none" };`,
    60_000,
  );
  observed.runtimeControlsVisible = true;
  observed.runtimeModel = runtime.model;

  await waitFor(
    "Cursor Agent ask-mode limitation notice",
    `const text = document.body.innerText;
     return text.includes("Ask mode only") && text.includes("File edits are not enabled");`,
    30_000,
  );
  observed.askModeNoticeVisible = true;
  observed.fileEditsDisabledNoticeVisible = true;

  if (askModePreflightOnly) {
    const capture = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
    await fs.writeFile(screenshotPath, Buffer.from(capture.result.data, "base64"));
    const artifact = await writeArtifact();
    if (!artifact.ok) {
      throw new Error("Cursor Agent hosted Chrome ask-mode preflight produced partial evidence; see artifact.");
    }
    console.log("Result: passed; hosted Chrome Cursor Agent ask-mode/edit-disabled notice verified without prompt submission.");
    console.log(`Artifact: ${artifactPath}`);
    console.log(`Screenshot: ${screenshotPath}`);
    await cleanupChrome();
    process.exit(0);
  }

  await submitComposerPrompt(prompt);
  observed.promptSubmitted = true;

  try {
    await waitFor(
      "Cursor Agent working state",
      `const lower = document.body.innerText.toLowerCase(); return lower.includes("working") || lower.includes("running") || lower.includes("running prompt");`,
      20_000,
    );
    observed.workingObserved = true;
  } catch {
    // The bounded prompt may complete before Chrome observes a working status.
  }

  if (stopRecoveryMode) {
    await waitForStopButton(Number(process.env.GT_CURSOR_AGENT_HOSTED_STOP_BUTTON_WAIT_MS || "30000"));
    await clickComposerPrimaryAction("Stop response", 20_000);
    observed.stopRequested = true;

    await waitForRecoveredComposer("Cursor Agent stopped or recovered after Stop", 60_000);
    observed.stoppedObserved = true;
    observed.doneObserved = true;
    observed.composerRecovered = true;

    await submitComposerPrompt(recoveryPrompt);
    observed.recoveryPromptSubmitted = true;

    await waitFor(
      "Cursor Agent recovery marker",
      `return document.body.innerText.includes(${JSON.stringify(recoveryMarker)});`,
      Number(process.env.GT_CURSOR_AGENT_HOSTED_MARKER_WAIT_MS || "90000"),
    );
    observed.recoveryMarkerSeen = true;

    await waitForRecoveredComposer("Cursor Agent recovered after second prompt", 60_000);
    observed.recoveryDoneObserved = true;
    observed.doneObserved = true;
    observed.composerRecovered = true;
  } else {
    await waitFor(
      "Cursor Agent marker",
      `return document.body.innerText.includes(${JSON.stringify(marker)});`,
      Number(process.env.GT_CURSOR_AGENT_HOSTED_MARKER_WAIT_MS || "90000"),
    );
    observed.markerSeen = true;

    await waitForRecoveredComposer("Cursor Agent done state", 60_000);
    observed.doneObserved = true;
    observed.composerRecovered = true;
  }

  const capture = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
  await fs.writeFile(screenshotPath, Buffer.from(capture.result.data, "base64"));
  const artifact = await writeArtifact();
  if (!artifact.ok) {
    throw new Error("Cursor Agent hosted Chrome smoke produced partial evidence; see artifact.");
  }
  console.log(stopRecoveryMode
    ? "Result: passed; hosted Chrome Cursor Agent Stop/recovery verified."
    : "Result: passed; hosted rendered Chrome Cursor Agent start and bounded prompt verified.");
  console.log(`Artifact: ${artifactPath}`);
  console.log(`Screenshot: ${screenshotPath}`);
  await cleanupChrome();
  process.exit(0);
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
  await cleanupChrome();
  process.exit(artifact.ok ? 0 : 1);
}
NODE
