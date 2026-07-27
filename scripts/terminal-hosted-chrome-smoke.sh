#!/usr/bin/env bash
# Verify Terminal through the hosted PWA rendered in Chrome's mobile viewport.
#
# This uses a disposable smoke account and an isolated local host harness. It
# drives the hosted UI: email sign-in, link-code claim, host open, Terminal open,
# command delivery, output rendering, interrupt, recovery command, and session
# controls including non-default session close fallback.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_URL="${GT_TERMINAL_HOSTED_APP_URL:-https://app.glasstunnel.io}"
DEBUG_PORT="${GT_TERMINAL_HOSTED_DEBUG_PORT:-9250}"
WIDTH="${GT_TERMINAL_HOSTED_WIDTH:-390}"
HEIGHT="${GT_TERMINAL_HOSTED_HEIGHT:-844}"
OUT_DIR="${GT_TERMINAL_HOSTED_OUT_DIR:-/tmp/glasstunnel-terminal-hosted}"
CHROME_BIN="${GT_MOBILE_CHROME_BIN:-}"

usage() {
  cat <<'USAGE'
Usage: pnpm qa:terminal:hosted-chrome

Loads .env.smoke.local, starts an isolated local Mac host harness, opens the
hosted PWA in Chrome's mobile viewport, signs in with the disposable email
account through the rendered UI, links the harness host, opens Terminal, sends
a command, observes output, interrupts a long command, verifies recovery, then
checks rendered Terminal session new/switch/rename/close controls, including
closing a non-default session back to the default session.

This is rendered hosted Chrome evidence. It is not physical-phone evidence.
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
host_label="${GT_TERMINAL_HOSTED_HOST_LABEL:-Terminal hosted Chrome $run_stamp}"

host_log="$(mktemp -t glasstunnel-terminal-hosted-host.XXXXXX.log)"
host_pid=""
cleanup() {
  if [[ -n "$host_pid" ]] && kill -0 "$host_pid" 2>/dev/null; then
    kill "$host_pid" 2>/dev/null || true
    wait "$host_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

GLASSTUNNEL_DEV=1 \
GLASSTUNNEL_KEYCHAIN_SUFFIX="${GT_TERMINAL_HOSTED_KEY_SUFFIX:-terminal-hosted-chrome-$run_stamp}" \
GT_TERMINAL_LIVE_HOST_SECONDS="${GT_TERMINAL_HOSTED_HOST_SECONDS:-240}" \
GT_TERMINAL_LIVE_HOST_LABEL="$host_label" \
swift run --package-path apps/host-macos TerminalLiveHostHarness >"$host_log" 2>&1 &
host_pid="$!"

host_device_id=""
link_code=""
deadline=$((SECONDS + 60))
while (( SECONDS < deadline )); do
  if ! kill -0 "$host_pid" 2>/dev/null; then
    echo "Terminal hosted host harness exited before link code." >&2
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
  echo "Timed out waiting for Terminal hosted host link code." >&2
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

GT_TERMINAL_HOSTED_CHROME="$CHROME_BIN" \
GT_TERMINAL_HOSTED_APP_URL="$APP_URL" \
GT_TERMINAL_HOSTED_DEBUG_PORT="$DEBUG_PORT" \
GT_TERMINAL_HOSTED_WIDTH="$WIDTH" \
GT_TERMINAL_HOSTED_HEIGHT="$HEIGHT" \
GT_TERMINAL_HOSTED_OUT_DIR="$OUT_DIR" \
GT_TERMINAL_HOSTED_HOST_DEVICE_ID="$host_device_id" \
GT_TERMINAL_HOSTED_HOST_LABEL="$host_label" \
GT_TERMINAL_HOSTED_LINK_CODE="$link_code" \
GT_TERMINAL_HOSTED_EMAIL="$SMOKE_EMAIL" \
GT_TERMINAL_HOSTED_PASSWORD="$SMOKE_PASSWORD" \
GT_TERMINAL_HOSTED_ACCESS_TOKEN="$access_token" \
node <<'NODE'
const { spawn } = await import("node:child_process");
const fs = await import("node:fs/promises");
const os = await import("node:os");
const path = await import("node:path");

const chromeBin = process.env.GT_TERMINAL_HOSTED_CHROME;
const appUrl = process.env.GT_TERMINAL_HOSTED_APP_URL.replace(/\/+$/, "");
const debugPort = process.env.GT_TERMINAL_HOSTED_DEBUG_PORT;
const width = Number(process.env.GT_TERMINAL_HOSTED_WIDTH || "390");
const height = Number(process.env.GT_TERMINAL_HOSTED_HEIGHT || "844");
const outDir = process.env.GT_TERMINAL_HOSTED_OUT_DIR || "/tmp/glasstunnel-terminal-hosted";
const hostDeviceId = process.env.GT_TERMINAL_HOSTED_HOST_DEVICE_ID;
const linkCode = process.env.GT_TERMINAL_HOSTED_LINK_CODE;
const email = process.env.GT_TERMINAL_HOSTED_EMAIL;
const password = process.env.GT_TERMINAL_HOSTED_PASSWORD;
const accessToken = process.env.GT_TERMINAL_HOSTED_ACCESS_TOKEN;
const signaling = process.env.GT_TERMINAL_LIVE_SIGNALING_URL || "wss://signaling.glasstunnel.io/signal";
const apiBase = signaling.replace(/^ws/i, "http").replace(/\/signal\/?$/, "");
const hostLabel = process.env.GT_TERMINAL_HOSTED_HOST_LABEL || "Terminal live smoke host";
const startedAt = Date.now();
const commandMarker = `GT_TERMINAL_RENDERED_${startedAt}_COMMAND`;
const recoveryMarker = `GT_TERMINAL_RENDERED_${startedAt}_RECOVERY`;
const newSessionMarker = `GT_TERMINAL_RENDERED_${startedAt}_SESSION_TWO`;
const defaultResumeMarker = `GT_TERMINAL_RENDERED_${startedAt}_DEFAULT_RESUME`;
const renamedSessionLabel = `Smoke Terminal ${String(startedAt).slice(-6)}`;
const profile = await fs.mkdtemp(path.join(os.tmpdir(), "gt-terminal-hosted-chrome."));
const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
const screenshotPath = path.join(outDir, `chrome-mobile-terminal-hosted-${timestamp}.png`);
const artifactPath = path.join(outDir, `terminal-hosted-chrome-${timestamp}.json`);
const observed = {
  ok: false,
  appUrl,
  hostDeviceId,
  hostLabel,
  commandMarkerSeen: false,
  longRunningObserved: false,
  interruptClicked: false,
  recoveryMarkerSeen: false,
  newSessionStarted: false,
  newSessionOutputIsolated: false,
  newSessionMarkerSeen: false,
  nonDefaultSessionClosed: false,
  defaultSessionSelected: false,
  defaultSessionResumed: false,
  sessionRenamed: false,
  sessionClosed: false,
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
      observed.commandMarkerSeen &&
      observed.interruptClicked &&
      observed.recoveryMarkerSeen &&
      observed.newSessionStarted &&
      observed.newSessionOutputIsolated &&
      observed.newSessionMarkerSeen &&
      observed.nonDefaultSessionClosed &&
      observed.defaultSessionResumed &&
      observed.sessionRenamed &&
      observed.sessionClosed,
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

  const query = new URLSearchParams({ terminalSmoke: String(startedAt) });
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
    const text = await bodyText().catch(() => "");
    throw new Error(`Timed out waiting for ${label}. Visible text: ${String(text).slice(0, 600)}`);
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
    await waitFor(
      `host ${hostName} button ${labels.join(", ")}`,
      `return Boolean((() => { ${candidateSource} })());`,
      timeoutMs,
    );
    const clicked = await evaluate(`(() => {
      const button = (() => { ${candidateSource} })();
      if (!button) return false;
      button.click();
      return true;
    })()`);
    if (!clicked) throw new Error(`Could not click host ${hostName} button: ${labels.join(", ")}`);
  };

  const clickButtonContaining = async (label, timeoutMs = 20_000) => {
    await waitFor(
      `button containing ${label}`,
      `return Array.from(document.querySelectorAll("button")).some((button) => button.innerText.includes(${JSON.stringify(label)}) && !button.disabled);`,
      timeoutMs,
    );
    const clicked = await evaluate(`(() => {
      const button = Array.from(document.querySelectorAll("button")).find((candidate) => candidate.innerText.includes(${JSON.stringify(label)}) && !candidate.disabled);
      if (!button) return false;
      button.click();
      return true;
    })()`);
    if (!clicked) throw new Error(`Could not click button containing ${label}`);
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

  await waitFor("workspace", `return document.body.innerText.includes("Coding apps") || document.body.innerText.includes("Terminal");`, 45_000);
  await clickButton("Terminal", 30_000);
  await waitFor("Terminal start panel", `return document.body.innerText.includes("Open Terminal on this Mac.") || document.body.innerText.includes("Type a terminal command");`, 45_000);

  const terminalEntryText = await bodyText();
  if (terminalEntryText.includes("Type a terminal command") && terminalEntryText.includes("Close")) {
    await clickButtonByAria("Close Terminal session", 20_000);
    await waitFor(
      "Terminal reset open state",
      `const text = document.body.innerText; return text.includes("Open Terminal on this Mac.") && !text.includes("Type a terminal command");`,
      45_000,
    );
  }

  if (!(await bodyText()).includes("Type a terminal command")) {
    await clickButton("Open Terminal", 30_000);
    await waitFor("Terminal composer", `return document.body.innerText.includes("Type a terminal command") || Boolean(document.querySelector('textarea[placeholder*="terminal command"]'));`, 45_000);
  }

  await fillInput("textarea", `export GT_HOSTED_SESSION_KIND=default; printf '${commandMarker}\\n'`);
  await clickButtonByAria("Run command");
  await waitFor("Terminal command output", `return document.body.innerText.includes(${JSON.stringify(commandMarker)});`, 45_000);
  observed.commandMarkerSeen = true;

  await fillInput("textarea", "sleep 20");
  await clickButtonByAria("Run command");
  await waitFor("Terminal running state", `return document.body.innerText.toLowerCase().includes("running");`, 15_000);
  observed.longRunningObserved = true;

  await clickButtonByAria("Stop response", 20_000);
  observed.interruptClicked = true;
  await sleep(1_000);

  await waitFor("Terminal input after interrupt", `return !document.querySelector('textarea')?.disabled;`, 30_000);
  await fillInput("textarea", `printf '${recoveryMarker}\\n'`);
  await clickButtonByAria("Run command");
  await waitFor("Terminal recovery output", `return document.body.innerText.includes(${JSON.stringify(recoveryMarker)});`, 45_000);
  observed.recoveryMarkerSeen = true;

  await clickButton("New", 30_000);
  await waitFor("new Terminal session target", `return document.body.innerText.includes("Terminal 2");`, 45_000);
  observed.newSessionStarted = true;
  await waitFor(
    "fresh Terminal session without previous output",
    `const text = document.body.innerText; return text.includes("Terminal 2") && !text.includes(${JSON.stringify(commandMarker)}) && !text.includes(${JSON.stringify(recoveryMarker)});`,
    45_000,
  );
  observed.newSessionOutputIsolated = true;

  await fillInput("textarea", `export GT_HOSTED_SESSION_KIND=two; printf '${newSessionMarker}\\n'`);
  await clickButtonByAria("Run command");
  await waitFor("new Terminal session command output", `return document.body.innerText.includes(${JSON.stringify(newSessionMarker)});`, 45_000);
  observed.newSessionMarkerSeen = true;

  await clickButtonByAria("Close Terminal session", 20_000);
  await waitFor(
    "non-default Terminal session closed to default",
    `const text = document.body.innerText; const input = document.querySelector("textarea"); return text.includes("Default Terminal") && !text.includes("Terminal 2") && Boolean(input) && !input.disabled && (input.placeholder || "").toLowerCase().includes("terminal command");`,
    45_000,
  );
  observed.nonDefaultSessionClosed = true;
  observed.defaultSessionSelected = true;

  await waitFor(
    "Terminal input after session switch",
    `const text = document.body.innerText.toLowerCase(); const input = document.querySelector("textarea"); return input && !input.disabled && !text.includes("syncing") && !text.includes("switching terminal session");`,
    45_000,
  );
  await fillInput("textarea", `printf '${defaultResumeMarker}\\n'`);
  await clickButtonByAria("Run command");
  await waitFor(
    "default Terminal session resumed",
    `const text = document.body.innerText; return text.includes("Default Terminal") && text.includes(${JSON.stringify(recoveryMarker)}) && text.includes(${JSON.stringify(defaultResumeMarker)});`,
    45_000,
  );
  observed.defaultSessionResumed = true;

  await clickButtonByAria("Rename Terminal session", 20_000);
  await fillInput('input[aria-label="Terminal session name"]', renamedSessionLabel);
  await clickButton("Save", 20_000);
  await waitFor("renamed Terminal session label", `return document.body.innerText.includes(${JSON.stringify(renamedSessionLabel)});`, 30_000);
  observed.sessionRenamed = true;

  await clickButtonByAria("Close Terminal session", 20_000);
  await waitFor(
    "Terminal closed open state",
    `const text = document.body.innerText; return text.includes("Open Terminal on this Mac.") && !text.includes("Type a terminal command");`,
    45_000,
  );
  observed.sessionClosed = true;

  const capture = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
  await fs.writeFile(screenshotPath, Buffer.from(capture.result.data, "base64"));
  const artifact = await writeArtifact();
  if (!artifact.ok) throw new Error("Terminal hosted Chrome smoke did not satisfy all assertions.");
  console.log("Result: passed; hosted rendered Chrome Terminal command, output, interrupt, recovery, and session controls verified.");
  console.log(`Artifact: ${artifactPath}`);
  console.log(`Screenshot: ${screenshotPath}`);

  async function clickButtonByAria(label, timeoutMs = 20_000) {
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
