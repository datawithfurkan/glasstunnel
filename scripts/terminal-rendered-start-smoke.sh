#!/usr/bin/env bash
# Verify rendered Terminal start feedback in a real Chrome viewport.
#
# This is local rendered-browser evidence only. It does not require a signed-in
# account, live Mac app, or real phone, and it does not satisfy hosted/mobile
# Terminal command-delivery release gates.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${GT_TERMINAL_RENDERED_PORT:-5179}"
DEBUG_PORT="${GT_TERMINAL_RENDERED_DEBUG_PORT:-9249}"
WAIT_MS="${GT_TERMINAL_RENDERED_WAIT_MS:-2500}"
WIDTH="${GT_TERMINAL_RENDERED_WIDTH:-390}"
HEIGHT="${GT_TERMINAL_RENDERED_HEIGHT:-844}"
OUT_DIR="${GT_TERMINAL_RENDERED_OUT_DIR:-/tmp/glasstunnel-mobile-qa}"
SERVER_LOG="${TMPDIR:-/tmp}/glasstunnel-terminal-rendered-vite.log"
CHROME_BIN="${GT_MOBILE_CHROME_BIN:-}"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

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
rm -f "$SERVER_LOG"

pnpm --filter=@glasstunnel/mobile-pwa dev --host 127.0.0.1 --port "$PORT" --strictPort >"$SERVER_LOG" 2>&1 &
SERVER_PID="$!"

for _ in {1..60}; do
  if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    echo "PWA dev server exited early." >&2
    cat "$SERVER_LOG" >&2
    exit 1
  fi
  sleep 1
done

if ! curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
  echo "PWA dev server did not become ready." >&2
  cat "$SERVER_LOG" >&2
  exit 1
fi

GT_TERMINAL_RENDERED_URL="http://127.0.0.1:$PORT/?gtFixture=workspace-terminal-stopped" \
GT_TERMINAL_RENDERED_CHROME="$CHROME_BIN" \
GT_TERMINAL_RENDERED_DEBUG_PORT="$DEBUG_PORT" \
GT_TERMINAL_RENDERED_WAIT_MS="$WAIT_MS" \
GT_TERMINAL_RENDERED_WIDTH="$WIDTH" \
GT_TERMINAL_RENDERED_HEIGHT="$HEIGHT" \
GT_TERMINAL_RENDERED_OUT_DIR="$OUT_DIR" \
node <<'NODE'
const { spawn } = await import("node:child_process");
const fs = await import("node:fs/promises");
const os = await import("node:os");
const path = await import("node:path");

const chromeBin = process.env.GT_TERMINAL_RENDERED_CHROME;
const debugPort = process.env.GT_TERMINAL_RENDERED_DEBUG_PORT;
const url = process.env.GT_TERMINAL_RENDERED_URL;
const waitMs = Number(process.env.GT_TERMINAL_RENDERED_WAIT_MS || "2500");
const width = Number(process.env.GT_TERMINAL_RENDERED_WIDTH || "390");
const height = Number(process.env.GT_TERMINAL_RENDERED_HEIGHT || "844");
const outDir = process.env.GT_TERMINAL_RENDERED_OUT_DIR || "/tmp/glasstunnel-mobile-qa";
const profile = await fs.mkdtemp(path.join(os.tmpdir(), "gt-terminal-rendered-chrome."));
const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
const screenshotPath = path.join(outDir, `chrome-mobile-terminal-start-${timestamp}.png`);

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
    "about:blank",
  ],
  { stdio: "ignore" },
);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function cleanup() {
  chrome.kill("SIGTERM");
  await fs.rm(profile, { recursive: true, force: true });
}

try {
  for (let i = 0; i < 60; i += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${debugPort}/json/version`);
      if (response.ok) break;
    } catch {
      // Retry until Chrome exposes the debugging endpoint.
    }
    await sleep(100);
  }

  const tab = await fetch(`http://127.0.0.1:${debugPort}/json/new?${encodeURIComponent(url)}`, {
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

  const evaluate = async (expression) => {
    const response = await send("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (response.result.exceptionDetails) {
      throw new Error(response.result.exceptionDetails.text || "Chrome evaluation failed");
    }
    return response.result.result.value;
  };

  await send("Runtime.enable");
  await send("Page.enable");
  await send("Emulation.setDeviceMetricsOverride", {
    width,
    height,
    deviceScaleFactor: 2,
    mobile: true,
  });
  await sleep(waitMs);

  const initial = await evaluate(`(() => {
    const text = document.body.innerText;
    return {
      hasTitle: text.includes("Terminal is ready"),
      hasCopy: text.includes("Open Terminal on this Mac."),
      hasAction: Array.from(document.querySelectorAll("button")).some((button) => button.innerText.trim() === "Open Terminal"),
      hasComposer: text.includes("Type a terminal command"),
    };
  })()`);

  if (!initial.hasTitle || !initial.hasCopy || !initial.hasAction || initial.hasComposer) {
    throw new Error(`Initial Terminal start state was not rendered correctly: ${JSON.stringify(initial)}`);
  }

  const clicked = await evaluate(`(() => {
    const button = Array.from(document.querySelectorAll("button")).find((candidate) => candidate.innerText.trim() === "Open Terminal");
    if (!button) return false;
    button.click();
    return true;
  })()`);
  if (!clicked) {
    throw new Error("Open Terminal button was not clickable.");
  }

  await sleep(250);

  const pendingState = await evaluate(`(() => {
    const text = document.body.innerText;
    return {
      hasOpening: text.includes("Opening Terminal"),
      hasWaiting: text.includes("Waiting for your Mac."),
      hasRetry: Array.from(document.querySelectorAll("button")).some((button) => button.innerText.trim() === "Retry"),
      hasComposer: text.includes("Type a terminal command"),
    };
  })()`);

  if (!pendingState.hasOpening || !pendingState.hasWaiting || !pendingState.hasRetry || pendingState.hasComposer) {
    throw new Error(`Terminal pending start state was not rendered correctly: ${JSON.stringify(pendingState)}`);
  }

  const capture = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
  await fs.writeFile(screenshotPath, Buffer.from(capture.result.data, "base64"));
  console.log(`Chrome mobile Terminal start screenshot: ${screenshotPath}`);
  console.log("Result: passed; rendered Terminal start action shows immediate pending feedback without exposing the command composer.");
} finally {
  await cleanup();
}
NODE
