#!/usr/bin/env bash
# Verify desktop browser wheel input can operate mobile-style horizontal strips.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${GT_MOBILE_HORIZONTAL_SCROLL_PORT:-5177}"
DEBUG_PORT="${GT_MOBILE_HORIZONTAL_SCROLL_DEBUG_PORT:-9237}"
WAIT_MS="${GT_MOBILE_HORIZONTAL_SCROLL_WAIT_MS:-2500}"
CHROME_BIN="${GT_MOBILE_CHROME_BIN:-}"
SERVER_LOG="${TMPDIR:-/tmp}/glasstunnel-horizontal-scroll-vite.log"

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

GT_HORIZONTAL_SCROLL_URL="http://127.0.0.1:$PORT/?gtFixture=workspace-all-apps" \
GT_HORIZONTAL_SCROLL_CHROME="$CHROME_BIN" \
GT_HORIZONTAL_SCROLL_DEBUG_PORT="$DEBUG_PORT" \
GT_HORIZONTAL_SCROLL_WAIT_MS="$WAIT_MS" \
node <<'NODE'
const { spawn } = await import("node:child_process");
const fs = await import("node:fs/promises");
const os = await import("node:os");
const path = await import("node:path");

const chromeBin = process.env.GT_HORIZONTAL_SCROLL_CHROME;
const debugPort = process.env.GT_HORIZONTAL_SCROLL_DEBUG_PORT;
const url = process.env.GT_HORIZONTAL_SCROLL_URL;
const waitMs = Number(process.env.GT_HORIZONTAL_SCROLL_WAIT_MS || "2500");
const profile = await fs.mkdtemp(path.join(os.tmpdir(), "gt-horizontal-scroll-chrome."));
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
    "--window-size=640,844",
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

  await send("Runtime.enable");
  const setViewport = (width) => send("Emulation.setDeviceMetricsOverride", {
    width,
    height: 844,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await setViewport(640);
  await sleep(waitMs);

  const readState = async (label) => {
    const response = await send("Runtime.evaluate", {
      returnByValue: true,
      expression: `(() => {
        const el = document.querySelector('[aria-label="${label}"]');
        return {
          exists: Boolean(el),
          scrollLeft: el?.scrollLeft ?? null,
          scrollWidth: el?.scrollWidth ?? null,
          clientWidth: el?.clientWidth ?? null,
          maxScrollLeft: el ? Math.max(0, el.scrollWidth - el.clientWidth) : null,
        };
      })()`,
    });
    return response.result.result.value;
  };

  const waitFor = async (label, expression, timeoutMs = 5000) => {
    const deadline = Date.now() + timeoutMs;
    let lastValue = null;
    while (Date.now() < deadline) {
      const response = await send("Runtime.evaluate", {
        returnByValue: true,
        expression,
      });
      lastValue = response.result.result.value;
      if (lastValue) return;
      await sleep(150);
    }
    throw new Error(`Timed out waiting for ${label}: ${JSON.stringify(lastValue)}`);
  };

  const exerciseHorizontalStrip = async (label) => {
    const resetResult = await send("Runtime.evaluate", {
      returnByValue: true,
      expression: `(() => {
        const el = document.querySelector('[aria-label="${label}"]');
        if (!el) return { exists: false };
        el.scrollLeft = 0;
        el.dispatchEvent(new Event('scroll', { bubbles: true }));
        return { exists: true };
      })()`,
    });
    const reset = resetResult.result.result.value;
    if (!reset.exists) {
      throw new Error(`${label} strip was not rendered.`);
    }

    const before = await readState(label);
    if (!before.exists) {
      throw new Error(`${label} strip was not rendered.`);
    }
    if (before.maxScrollLeft <= 1) {
      throw new Error(`${label} strip did not overflow horizontally: ${JSON.stringify(before)}`);
    }

    await send("Runtime.evaluate", {
      returnByValue: true,
      expression: `(() => {
        const el = document.querySelector('[aria-label="${label}"]');
        el.dispatchEvent(new WheelEvent('wheel', { deltaY: 180, bubbles: true, cancelable: true }));
      })()`,
    });
    const after = await readState(label);
    if (!(after.scrollLeft > before.scrollLeft)) {
      throw new Error(`Wheel input did not move ${label} horizontally: before=${JSON.stringify(before)} after=${JSON.stringify(after)}`);
    }

    const edgeResult = await send("Runtime.evaluate", {
      returnByValue: true,
      expression: `(() => {
        const el = document.querySelector('[aria-label="${label}"]');
        el.scrollLeft = Math.max(0, el.scrollWidth - el.clientWidth);
        const event = new WheelEvent('wheel', { deltaY: 180, bubbles: true, cancelable: true });
        el.dispatchEvent(event);
        return { defaultPrevented: event.defaultPrevented, scrollLeft: el.scrollLeft };
      })()`,
    });
    const edge = edgeResult.result.result.value;
    if (edge.defaultPrevented) {
      throw new Error(`Wheel input was trapped at the ${label} horizontal edge: ${JSON.stringify(edge)}`);
    }
  };

  const verifyDesktopButtons = async (label) => {
    const resetResult = await send("Runtime.evaluate", {
      returnByValue: true,
      expression: `(() => {
        const el = document.querySelector('[aria-label="${label}"]');
        if (!el) return { exists: false };
        el.scrollLeft = 0;
        el.dispatchEvent(new Event('scroll', { bubbles: true }));
        return {
          exists: true,
          scrollLeft: el.scrollLeft,
          scrollWidth: el.scrollWidth,
          clientWidth: el.clientWidth,
          maxScrollLeft: Math.max(0, el.scrollWidth - el.clientWidth),
        };
      })()`,
    });
    const reset = resetResult.result.result.value;
    if (!reset.exists || reset.maxScrollLeft <= 1) {
      throw new Error(`${label} strip did not overflow before arrow test: ${JSON.stringify(reset)}`);
    }

    await sleep(150);
    const before = await readState(label);
    const buttonState = await send("Runtime.evaluate", {
      returnByValue: true,
      expression: `(() => {
        const button = document.querySelector('[aria-label="Scroll ${label} right"]');
        if (!button) return { exists: false, visible: false };
        const rect = button.getBoundingClientRect();
        const style = getComputedStyle(button);
        return {
          exists: true,
          visible: rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden',
          width: rect.width,
          height: rect.height,
        };
      })()`,
    });
    const button = buttonState.result.result.value;
    if (!button.exists || !button.visible) {
      throw new Error(`Desktop scroll button was not visible for ${label}: ${JSON.stringify(button)}`);
    }

    await send("Runtime.evaluate", {
      returnByValue: true,
      expression: `document.querySelector('[aria-label="Scroll ${label} right"]').click()`,
    });
    await sleep(500);
    const after = await readState(label);
    if (!(after.scrollLeft > before.scrollLeft)) {
      throw new Error(`Desktop scroll button did not move ${label}: before=${JSON.stringify(before)} after=${JSON.stringify(after)}`);
    }
  };

  await verifyDesktopButtons("Coding apps");
  await setViewport(390);
  await sleep(250);
  await exerciseHorizontalStrip("Coding apps");

  const openedThread = await send("Runtime.evaluate", {
    returnByValue: true,
    expression: `(() => {
      const isVisible = (element) => {
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };
      const projectButton = [...document.querySelectorAll('button')]
        .find((button) => isVisible(button) && /Glasstunnel 1/i.test(button.textContent || ''));
      projectButton?.click();
      return { projectOpened: Boolean(projectButton) };
    })()`,
  });
  const thread = openedThread.result.result.value;
  if (!thread.projectOpened) {
    throw new Error(`Could not open fixture Codex thread: ${JSON.stringify(thread)}`);
  }
  await sleep(250);

  const openedPromptActions = await send("Runtime.evaluate", {
    returnByValue: true,
    expression: `(() => {
      const isVisible = (element) => {
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };
      const actionsButton = [...document.querySelectorAll('button')]
        .find((button) => isVisible(button) && (button.textContent || '').trim() === 'Actions');
      actionsButton?.click();
      return { actionsOpened: Boolean(actionsButton) };
    })()`,
  });
  const opened = openedPromptActions.result.result.value;
  if (!opened.actionsOpened) {
    throw new Error(`Could not open prompt action strip: ${JSON.stringify(opened)}`);
  }
  await sleep(250);
  await verifyDesktopButtons("Prompt actions");
  await exerciseHorizontalStrip("Prompt actions");

  await setViewport(640);
  await send("Runtime.evaluate", {
    returnByValue: true,
    expression: `location.href = "http://127.0.0.1:${process.env.GT_MOBILE_HORIZONTAL_SCROLL_PORT || "5177"}/?gtFixture=workspace-terminal-running&app=terminal"`,
  });
  await sleep(waitMs);
  await waitFor("Terminal target strip", `(() => {
    const text = document.body.innerText;
    return text.includes("Default Terminal") &&
      text.includes("Build shell") &&
      Boolean(document.querySelector('[aria-label="Available targets"]'));
  })()`, 10_000);
  await verifyDesktopButtons("Available targets");
  await setViewport(390);
  await sleep(250);
  await exerciseHorizontalStrip("Available targets");

  console.log("Result: passed; desktop buttons moved the app switcher, prompt actions, and Terminal targets; desktop wheel moved all three horizontal strips and released at their edges.");
} finally {
  await cleanup();
}
NODE
