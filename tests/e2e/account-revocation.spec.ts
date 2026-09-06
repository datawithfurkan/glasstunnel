import { expect, test, type Page } from '@playwright/test';
import { readFile, writeFile, rename, rm } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';

test('@revocation-account host permissions and revocation isolate two browsers', async ({ page, browser, baseURL }, testInfo) => {
  test.setTimeout(120_000);
  const control = process.env.GT_LAB_REVOCATION_CONTROL;
  if (!control) throw new Error('Use the local lab runner for revocation tests.');
  const secondContext = await browser.newContext({ baseURL, viewport: { width: 390, height: 844 } });
  const second = await secondContext.newPage();
  const states: unknown[] = [];
  for (const [name, target] of [['first', page], ['second', second]] as const) {
    target.on('websocket', (socket) => socket.on('framereceived', ({ payload }) => {
      try {
        const message = JSON.parse(String(payload));
        if (message.type === 'relay_agent_state' && message.snapshot?.agentId === 'terminal') {
          states.push({ browser: name, cached: message.cached === true, status: message.snapshot.status, detail: message.snapshot.statusDetail });
        } else if (message.type === 'relay_presence') {
          states.push({ browser: name, online: message.online });
        }
        if (states.length > 100) states.shift();
      } catch { /* Ignore binary and non-status frames. */ }
    }));
  }

  async function signIn(target: Page) {
    await target.goto('/?authProvider=email');
    await target.getByPlaceholder('you@example.com').fill(process.env.GT_LAB_EMAIL!);
    await target.getByRole('button', { name: 'Continue with email', exact: true }).click();
    await target.getByPlaceholder('Enter your password').fill(process.env.GT_LAB_PASSWORD!);
    await target.getByRole('button', { name: 'Sign in', exact: true }).last().click();
    // The first browser has already claimed this disposable host.
    await expect(target.getByRole('heading', { name: 'Your Macs', exact: true })).toBeVisible();
    await target.getByRole('button', { name: 'Open', exact: true }).first().click();
    await expect(target.getByRole('button', { name: 'Terminal', exact: true }).filter({ visible: true }).first()).toBeVisible({ timeout: 20_000 });
  }

  async function marker(target: Page, text: string, newSession = false) {
    const terminal = target.getByRole('button', { name: 'Terminal', exact: true }).filter({ visible: true }).first();
    const openHost = target.getByRole('button', { name: 'Open', exact: true }).first();
    const input = target.getByPlaceholder('Type a terminal command...').filter({ visible: true });
    if (!(await input.isVisible())) {
      await expect(terminal.or(openHost).first()).toBeVisible({ timeout: 20_000 });
      if (await openHost.isVisible()) await openHost.click();
      await terminal.click();
    }
    const open = target.getByRole('button', { name: 'Open Terminal', exact: true }).filter({ visible: true });
    if (await open.isVisible()) await open.click();
    await expect(input).toBeEnabled({ timeout: 20_000 });
    if (newSession) {
      const currentSession = target.getByRole('button', { name: /^Current session:/ }).filter({ visible: true });
      const previousSession = await currentSession.isVisible() ? await currentSession.getAttribute('aria-label') : null;
      await target.getByRole('button', { name: 'Start a new Terminal session' }).filter({ visible: true }).click({ timeout: 20_000 });
      await expect(currentSession).toBeVisible({ timeout: 20_000 });
      if (previousSession) await expect(currentSession).not.toHaveAttribute('aria-label', previousSession);
      await expect(input).toBeEnabled({ timeout: 20_000 });
    }
    const split = Math.floor(text.length / 2);
    await input.fill(`printf '%s%s\\n' '${text.slice(0, split)}' '${text.slice(split)}'`);
    await target.getByRole('button', { name: 'Run command' }).filter({ visible: true }).click();
    await expect(target.locator('pre').filter({ hasText: text, visible: true }).first()).toBeVisible({ timeout: 20_000 });
    await expect(target.getByTestId('agent-status-badge').filter({ visible: true })).toHaveText('ready', { timeout: 20_000 });
  }

  try {
    // A fresh run claims the disposable host with this browser before the second signs in.
    await page.goto(`/?authProvider=email&linkCode=${encodeURIComponent(process.env.GT_LAB_LINK_CODE!)}`);
    await page.getByPlaceholder('you@example.com').fill(process.env.GT_LAB_EMAIL!);
    await page.getByRole('button', { name: 'Continue with email', exact: true }).click();
    await page.getByPlaceholder('Enter your password').fill(process.env.GT_LAB_PASSWORD!);
    await page.getByRole('button', { name: 'Sign in', exact: true }).last().click();
    // Never run markers in an existing user's default Terminal session.
    await marker(page, 'REVOCATION_BEFORE', true);
    await signIn(second);
    await marker(second, 'SECOND_BROWSER_BEFORE');
    const deviceID = await page.evaluate(async () => {
      // Development-only state read; never copy tokens or private keys to Node/logs.
      const modulePath = '/src/lib/store.ts';
      const { useAppStore } = await import(/* @vite-ignore */ modulePath);
      return useAppStore.getState().phoneKeypair.deviceId as string;
    });
    async function setHostReadOnly(hostReadOnly: boolean) {
      const requestID = randomUUID();
      await writeFile(control + '.tmp', JSON.stringify({ requestID, deviceID, hostReadOnly }), { mode: 0o600 });
      await rename(control + '.tmp', control);
      await expect.poll(async () => {
        try { return JSON.parse(await readFile(control + '.result', 'utf8')); }
        catch { return null; }
      }).toEqual({ requestID, confirmed: true });
    }
    await setHostReadOnly(true);
    for (const target of [page, second]) {
      await expect(target.getByText('Read-only on this Mac. Change access in Mac Settings.')).toBeVisible();
      await expect(target.getByRole('textbox', { name: 'Read-only mode', exact: true }).filter({ visible: true })).toBeDisabled();
      await expect(target.getByRole('button', { name: 'Start a new Terminal session' }).filter({ visible: true })).toBeDisabled();
    }
    await page.evaluate(async () => {
      const modulePath = '/src/lib/store.ts';
      const { useAppStore } = await import(/* @vite-ignore */ modulePath);
      const relay = useAppStore.getState().relay;
      // Bypass the UI/store guards to exercise the actual host boundary.
      relay.sendReadOnlyUpdate(false);
      relay.sendUserInput({ agentId: 'terminal', text: "printf '%s%s\\n' 'FORGED_' 'CONTROL_EXECUTED'", submitOnSend: true });
    });
    await expect(page.getByText('action blocked: read-only mode is on', { exact: true })).toBeVisible();
    await expect(second.getByText('action blocked: read-only mode is on', { exact: true })).toHaveCount(0);
    await expect(page.locator('pre').filter({ hasText: 'FORGED_CONTROL_EXECUTED', visible: true })).toHaveCount(0);
    await page.screenshot({ path: testInfo.outputPath('host-read-only.png'), fullPage: true });
    await setHostReadOnly(false);
    await expect(page.getByText('Read-only on this Mac. Change access in Mac Settings.')).toHaveCount(0);
    await marker(second, 'HOST_CONTROL_RESTORED');
    await page.getByRole('button', { name: 'Open menu' }).click();
    await page.getByRole('checkbox', { name: 'Read-only in this browser' }).check();
    await page.getByRole('button', { name: 'Open menu' }).click();
    await expect(page.getByRole('textbox', { name: 'Read-only mode', exact: true }).filter({ visible: true })).toBeDisabled();
    await marker(second, 'SECOND_BROWSER_STILL_CONTROLS');
    const requestID = randomUUID();
    await writeFile(control + '.tmp', JSON.stringify({ requestID, deviceID }), { mode: 0o600 });
    await rename(control + '.tmp', control);
    await expect.poll(async () => {
      try { return JSON.parse(await readFile(control + '.result', 'utf8')); }
      catch { return null; }
    }, { timeout: 35_000 }).toEqual({ requestID, confirmed: true });
    await expect(page.getByText(/Access to this Mac was revoked/)).toBeVisible();
    await expect(page.getByRole('textbox', { name: 'Read-only mode', exact: true })).toHaveCount(0);
    await page.screenshot({ path: testInfo.outputPath('access-revoked.png'), fullPage: true });
    await marker(second, 'SECOND_BROWSER_AFTER');
    await page.reload();
    await expect(page.getByRole('heading', { name: 'Your Macs', exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Open', exact: true })).toHaveCount(0);
  } finally {
    await testInfo.attach('terminal-status', { body: JSON.stringify(states), contentType: 'application/json' });
    for (const path of [control, control + '.tmp', control + '.result']) await rm(path, { force: true });
    await secondContext.close().catch((error) => {
      if (testInfo.status !== 'timedOut') throw error;
    });
  }
});
