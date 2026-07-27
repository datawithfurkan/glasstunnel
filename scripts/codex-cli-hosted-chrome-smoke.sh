#!/usr/bin/env bash
# Verify Codex CLI through the hosted PWA rendered in Chrome's mobile viewport.
#
# This uses the same disposable smoke-account and isolated local host harness
# pattern as the Terminal hosted smoke, but targets the direct Codex CLI app
# surface: link host, start Codex CLI, exercise runtime controls, send one
# bounded prompt, request stop, and record what actually happened.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_URL="${GT_CODEX_CLI_HOSTED_APP_URL:-https://app.glasstunnel.io}"
DEBUG_PORT="${GT_CODEX_CLI_HOSTED_DEBUG_PORT:-9251}"
WIDTH="${GT_CODEX_CLI_HOSTED_WIDTH:-390}"
HEIGHT="${GT_CODEX_CLI_HOSTED_HEIGHT:-844}"
OUT_DIR="${GT_CODEX_CLI_HOSTED_OUT_DIR:-/tmp/glasstunnel-codex-cli-hosted}"
CHROME_BIN="${GT_MOBILE_CHROME_BIN:-}"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:codex-cli:hosted-chrome

Loads .env.platform.local and .env.smoke.local, starts an isolated local Mac
host harness, opens the hosted PWA in Chrome's mobile viewport, signs in with
the disposable email account, links the harness host, starts Codex CLI, drives
runtime controls, sends one bounded prompt, requests stop, and records JSON plus
screenshot artifacts.

This is rendered hosted Chrome evidence. It can consume a small amount of Codex
CLI model quota. It is not physical-phone or Safari evidence.
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
host_label="${GT_CODEX_CLI_HOSTED_HOST_LABEL:-Codex CLI hosted Chrome $run_stamp}"

host_log="$(mktemp -t glasstunnel-codex-cli-hosted-host.XXXXXX.log)"
host_pid=""
cleanup() {
  if [[ -n "$host_pid" ]] && kill -0 "$host_pid" 2>/dev/null; then
    kill "$host_pid" 2>/dev/null || true
    wait "$host_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

GLASSTUNNEL_DEV=1 \
GLASSTUNNEL_KEYCHAIN_SUFFIX="${GT_CODEX_CLI_HOSTED_KEY_SUFFIX:-codex-cli-hosted-chrome-$run_stamp}" \
GT_TERMINAL_LIVE_HOST_SECONDS="${GT_CODEX_CLI_HOSTED_HOST_SECONDS:-300}" \
GT_TERMINAL_LIVE_HOST_LABEL="$host_label" \
swift run --package-path apps/host-macos TerminalLiveHostHarness >"$host_log" 2>&1 &
host_pid="$!"

host_device_id=""
link_code=""
deadline=$((SECONDS + 60))
while (( SECONDS < deadline )); do
  if ! kill -0 "$host_pid" 2>/dev/null; then
    echo "Codex CLI hosted host harness exited before link code." >&2
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
  echo "Timed out waiting for Codex CLI hosted host link code." >&2
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

GT_CODEX_CLI_HOSTED_CHROME="$CHROME_BIN" \
GT_CODEX_CLI_HOSTED_APP_URL="$APP_URL" \
GT_CODEX_CLI_HOSTED_DEBUG_PORT="$DEBUG_PORT" \
GT_CODEX_CLI_HOSTED_WIDTH="$WIDTH" \
GT_CODEX_CLI_HOSTED_HEIGHT="$HEIGHT" \
GT_CODEX_CLI_HOSTED_OUT_DIR="$OUT_DIR" \
GT_CODEX_CLI_HOSTED_HOST_DEVICE_ID="$host_device_id" \
GT_CODEX_CLI_HOSTED_HOST_LABEL="$host_label" \
GT_CODEX_CLI_HOSTED_LINK_CODE="$link_code" \
GT_CODEX_CLI_HOSTED_EMAIL="$SMOKE_EMAIL" \
GT_CODEX_CLI_HOSTED_PASSWORD="$SMOKE_PASSWORD" \
GT_CODEX_CLI_HOSTED_ACCESS_TOKEN="$access_token" \
node <<'NODE'
const { spawn } = await import("node:child_process");
const fs = await import("node:fs/promises");
const os = await import("node:os");
const path = await import("node:path");

const chromeBin = process.env.GT_CODEX_CLI_HOSTED_CHROME;
const appUrl = process.env.GT_CODEX_CLI_HOSTED_APP_URL.replace(/\/+$/, "");
const debugPort = process.env.GT_CODEX_CLI_HOSTED_DEBUG_PORT;
const width = Number(process.env.GT_CODEX_CLI_HOSTED_WIDTH || "390");
const height = Number(process.env.GT_CODEX_CLI_HOSTED_HEIGHT || "844");
const outDir = process.env.GT_CODEX_CLI_HOSTED_OUT_DIR || "/tmp/glasstunnel-codex-cli-hosted";
const hostDeviceId = process.env.GT_CODEX_CLI_HOSTED_HOST_DEVICE_ID;
const linkCode = process.env.GT_CODEX_CLI_HOSTED_LINK_CODE;
const email = process.env.GT_CODEX_CLI_HOSTED_EMAIL;
const password = process.env.GT_CODEX_CLI_HOSTED_PASSWORD;
const accessToken = process.env.GT_CODEX_CLI_HOSTED_ACCESS_TOKEN;
const signaling = process.env.GT_TERMINAL_LIVE_SIGNALING_URL || "wss://signaling.glasstunnel.io/signal";
const apiBase = signaling.replace(/^ws/i, "http").replace(/\/signal\/?$/, "");
const hostLabel = process.env.GT_CODEX_CLI_HOSTED_HOST_LABEL || "Codex CLI hosted smoke host";
const startedAt = Date.now();
const marker = `GT_CODEX_HOSTED_${startedAt}`;
const recoveryMarker = `GT_CODEX_RECOVERY_${startedAt}`;
const prompt = process.env.GT_CODEX_CLI_HOSTED_PROMPT || `Reply with exactly ${marker}, then stop.`;
const recoveryPrompt = process.env.GT_CODEX_CLI_HOSTED_RECOVERY_PROMPT || `Reply with exactly ${recoveryMarker}.`;
const profile = await fs.mkdtemp(path.join(os.tmpdir(), "gt-codex-cli-hosted-chrome."));
const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
const screenshotPath = path.join(outDir, `chrome-mobile-codex-cli-hosted-${timestamp}.png`);
const artifactPath = path.join(outDir, `codex-cli-hosted-chrome-${timestamp}.json`);
const observed = {
  ok: false,
  appUrl,
  hostDeviceId,
  hostLabel,
  marker,
  recoveryMarker,
  codexCliVisible: false,
  started: false,
  runtimeControlsVisible: false,
  runtimeModelOptions: [],
  runtimeInitialModel: null,
  runtimeAppliedModel: null,
  runtimeInitialEffort: null,
  runtimeInitialFast: null,
  runtimeModelChanged: false,
  runtimeEffortChanged: false,
  runtimeFastToggled: false,
  promptSubmitted: false,
  workingObserved: false,
  stopRequested: false,
  doneOrStoppedObserved: false,
  restartedAfterStop: false,
  composerRecoveredAfterStop: false,
  recoveryPromptSubmitted: false,
  recoveryMarkerSeen: false,
  recoveryDoneObserved: false,
  markerSeen: false,
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
  const payload = {
    ...observed,
    ok: !error &&
      observed.codexCliVisible &&
      observed.started &&
      observed.runtimeControlsVisible &&
      observed.runtimeModelChanged &&
      observed.runtimeEffortChanged &&
      observed.runtimeFastToggled &&
      observed.promptSubmitted &&
      observed.stopRequested &&
      observed.markerSeen &&
      observed.doneOrStoppedObserved &&
      observed.restartedAfterStop &&
      observed.composerRecoveredAfterStop &&
      observed.recoveryPromptSubmitted &&
      observed.recoveryMarkerSeen &&
      observed.recoveryDoneObserved,
    error: error ? String(error.message || error) : undefined,
  };
  await fs.writeFile(artifactPath, `${JSON.stringify(payload, null, 2)}\n`);
  return payload;
}

try {
  for (let i = 0; i < 80; i += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${debugPort}/json/version`);
      if (response.ok) break;
    } catch {
      // Retry until Chrome exposes the debugging endpoint.
    }
    await sleep(100);
  }

  const query = new URLSearchParams({ app: "codex-cli", codexCliHostedSmoke: String(startedAt) });
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
      if (select.disabled) return false;
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

  await waitFor("workspace", `return document.body.innerText.includes("Coding apps") || document.body.innerText.includes("Codex CLI");`, 45_000);
  const codexSurfaceReady = await waitFor(
    "direct Codex CLI surface",
    `const text = document.body.innerText;
     return text.includes("Start Codex CLI on this Mac") ||
       text.includes("Codex CLI stopped") ||
       text.includes("Model") ||
       text.includes("OpenAI Codex");`,
    15_000,
  ).then(() => true).catch(() => false);
  if (!codexSurfaceReady) {
    await clickButton("CLI", 30_000);
  }
  await waitFor(
    "Codex CLI surface",
    `const text = document.body.innerText;
     return text.includes("Start Codex CLI on this Mac") ||
       text.includes("Codex CLI stopped") ||
       text.includes("Model") ||
       text.includes("OpenAI Codex");`,
    45_000,
  );
  observed.codexCliVisible = true;

  if ((await bodyText()).includes("Start Codex CLI on this Mac") || (await bodyText()).includes("Codex CLI stopped")) {
    await clickButton("Start", 30_000);
  }
  await waitFor(
    "Codex CLI started or controls visible",
    `const text = document.body.innerText; return text.includes("Codex CLI") && (text.includes("Model") || text.includes("OpenAI Codex") || text.includes("Send a prompt") || text.includes("WORKING") || text.includes("READY"));`,
    90_000,
  );
  observed.started = true;

  const runtime = await waitFor(
    "Codex CLI runtime controls",
    `const model = document.querySelector('select[aria-label="Model"]');
     const effort = document.querySelector('select[aria-label="Effort"]');
     const fast = Array.from(document.querySelectorAll("button")).find((button) => button.innerText.trim() === "Fast");
     if (!model || !effort || !fast) return false;
     return {
       model: model.value || null,
       modelOptions: Array.from(model.options).map((option) => ({ value: option.value, text: option.text })),
       effort: effort.value || null,
       effortOptions: Array.from(effort.options).map((option) => ({ value: option.value, text: option.text })),
       fast: fast.getAttribute("aria-pressed") === "true",
     };`,
    60_000,
  );
  observed.runtimeControlsVisible = true;
  observed.runtimeInitialModel = runtime.model;
  observed.runtimeInitialEffort = runtime.effort;
  observed.runtimeInitialFast = runtime.fast;
  observed.runtimeModelOptions = runtime.modelOptions;

  const effortOptions = runtime.effortOptions.map((option) => option.value).filter(Boolean);
  const nextEffort = effortOptions.find((value) => value !== runtime.effort) || runtime.effort;
  if (nextEffort && nextEffort !== runtime.effort) {
    await selectValue('select[aria-label="Effort"]', nextEffort);
    await waitFor("runtime effort applied", `const select = document.querySelector('select[aria-label="Effort"]'); return select && select.value === ${JSON.stringify(nextEffort)};`, 30_000);
    observed.runtimeEffortChanged = true;
    await sleep(2_000);
  }

  await clickButton("Fast", 120_000);
  await waitFor(
    "runtime fast toggled",
    `const fast = Array.from(document.querySelectorAll("button")).find((button) => button.innerText.trim() === "Fast"); return fast && fast.getAttribute("aria-pressed") === ${JSON.stringify(String(!runtime.fast))};`,
    30_000,
  );
  observed.runtimeFastToggled = true;
  await sleep(3_000);

  await waitFor("prompt composer enabled", `const input = document.querySelector("textarea"); return input && !input.disabled && (input.placeholder || "").includes("prompt");`, 60_000);
  await fillInput("textarea", prompt);
  await clickButtonByAria("Send prompt", 20_000);
  observed.promptSubmitted = true;

  try {
    await waitFor("Codex CLI working state", `return document.body.innerText.toLowerCase().includes("working") || document.body.innerText.toLowerCase().includes("running");`, 25_000);
    observed.workingObserved = true;
  } catch {
    // Prompt may complete quickly or the TUI may not expose a clean working label.
  }

  try {
    await waitFor(
      "Codex CLI prompt marker",
      `return document.body.innerText.includes(${JSON.stringify(marker)});`,
      Number(process.env.GT_CODEX_CLI_HOSTED_MARKER_WAIT_MS || "30000"),
    );
    observed.markerSeen = true;
  } catch {
    // Keep the artifact as diagnostic evidence if the model did not return the marker.
  }

  await clickButtonByAria("Stop response", 30_000);
  observed.stopRequested = true;
  await sleep(Number(process.env.GT_CODEX_CLI_HOSTED_STOP_WAIT_MS || "5000"));

  try {
    await waitFor(
      "Codex CLI done or stopped state",
      `const text = document.body.innerText.toLowerCase(); return text.includes("ready") || text.includes("stopped") || text.includes("stop requested") || text.includes("interrupted") || text.includes("prompt returned");`,
      30_000,
    );
    observed.doneOrStoppedObserved = true;
  } catch {
    // Keep the artifact as diagnostic evidence if stop/done is still not visible.
  }

  const stoppedBeforeModelSwitch = await bodyText().then((text) =>
    text.includes("Codex CLI stopped") || text.includes("Start Codex CLI on this Mac")
  ).catch(() => false);
  if (stoppedBeforeModelSwitch) {
    await clickButton("Start", 30_000);
  }
  observed.restartedAfterStop = true;
  await waitFor(
    "Codex CLI ready after prompt/stop restart",
    `const text = document.body.innerText.toLowerCase();
     return text.includes("ready") || text.includes("prompt returned");`,
    90_000,
  );
  await waitFor(
    "Codex CLI composer recovered after prompt/stop",
    `const input = document.querySelector("textarea");
     return input && !input.disabled && (input.placeholder || "").includes("prompt");`,
    90_000,
  );
  observed.composerRecoveredAfterStop = true;

  await fillInput("textarea", recoveryPrompt);
  await clickButtonByAria("Send prompt", 20_000);
  observed.recoveryPromptSubmitted = true;

  await waitFor(
    "Codex CLI recovery prompt marker",
    `return document.body.innerText.includes(${JSON.stringify(recoveryMarker)});`,
    Number(process.env.GT_CODEX_CLI_HOSTED_RECOVERY_MARKER_WAIT_MS || "45000"),
  );
  observed.recoveryMarkerSeen = true;

  await waitFor(
    "Codex CLI recovery prompt visibly idle",
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
       (input.placeholder || "").includes("prompt") &&
       !stopButtonVisible &&
       !compactStatusText.includes("running") &&
       !compactStatusText.includes("working") &&
       !lower.includes("waiting for codex output") &&
       (compactStatusText.includes("ready") || lower.includes("prompt returned"));`,
    45_000,
  );
  observed.recoveryDoneObserved = true;

  await waitFor(
    "Codex CLI controls enabled after recovery prompt",
    `const model = document.querySelector('select[aria-label="Model"]');
     const input = document.querySelector("textarea");
     return model && !model.disabled && input && !input.disabled && (input.placeholder || "").includes("prompt");`,
    90_000,
  );

  const modelControl = await waitFor(
    "Codex CLI model control after prompt/stop",
    `const model = document.querySelector('select[aria-label="Model"]');
     if (!model) return false;
     return {
       model: model.value || null,
       modelOptions: Array.from(model.options).map((option) => ({ value: option.value, text: option.text })),
     };`,
    90_000,
  );
  const modelOptions = modelControl.modelOptions.map((option) => option.value).filter(Boolean);
  const nextModel = modelOptions.find((value) => value !== modelControl.model);
  if (!nextModel) {
    throw new Error("Codex CLI model control had no alternate selectable model.");
  }
  await selectValue('select[aria-label="Model"]', nextModel);
  const appliedModel = await waitFor(
    "runtime model applied",
    `const model = document.querySelector('select[aria-label="Model"]');
     return model && model.value === ${JSON.stringify(nextModel)} ? model.value : false;`,
    30_000,
  );
  observed.runtimeAppliedModel = appliedModel;
  observed.runtimeModelChanged = true;
  observed.runtimeModelOptions = modelControl.modelOptions;
  await waitFor(
    "Codex CLI visibly idle before screenshot",
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
       (input.placeholder || "").includes("prompt") &&
       !stopButtonVisible &&
       !compactStatusText.includes("running") &&
       !compactStatusText.includes("working") &&
       !lower.includes("waiting for codex output") &&
       (compactStatusText.includes("ready") || lower.includes("prompt returned"));`,
    90_000,
  );

  const capture = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
  await fs.writeFile(screenshotPath, Buffer.from(capture.result.data, "base64"));
  const artifact = await writeArtifact();
  if (!artifact.ok) {
    throw new Error("Codex CLI hosted Chrome smoke produced partial evidence; see artifact.");
  }
  console.log("Result: passed; hosted rendered Chrome Codex CLI start, runtime controls, prompt, stop, and recovery prompt verified.");
  console.log(`Artifact: ${artifactPath}`);
  console.log(`Screenshot: ${screenshotPath}`);
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
