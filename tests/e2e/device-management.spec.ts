import { expect, test, type Page } from '@playwright/test';

// Local lab only: node scripts/lab/e2e.mjs device-management (pnpm lab:e2e:device-management).
// The journey removes the lab Mac from the lab account, so it runs alone.

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required; run this journey with node scripts/lab/e2e.mjs device-management.`);
  return value;
}

interface RelaySocketRecord {
  frames: string[];
  closed: boolean;
}

async function signIn(page: Page, linkCode?: string) {
  const code = linkCode ? `&linkCode=${encodeURIComponent(linkCode)}` : '';
  await page.goto(`/?authProvider=email${code}`);
  await page.getByPlaceholder('you@example.com').fill(requiredEnv('GT_LAB_EMAIL'));
  await page.getByRole('button', { name: 'Continue with email', exact: true }).click();
  await page.getByPlaceholder('Enter your password').fill(requiredEnv('GT_LAB_PASSWORD'));
  await page.getByRole('button', { name: 'Sign in', exact: true }).last().click();
}

/** Opens the account's Mac (or waits for the claim to open it) until its workspace shows. */
async function openWorkspace(page: Page) {
  const terminalTab = page.getByRole('button', { name: 'Terminal', exact: true }).filter({ visible: true }).first();
  const openMac = page.getByRole('button', { name: 'Open', exact: true }).first();
  await expect(terminalTab.or(openMac).first()).toBeVisible({ timeout: 25_000 });
  if (await openMac.isVisible()) await openMac.click();
  await expect(terminalTab).toBeVisible({ timeout: 25_000 });
}

/**
 * Goes to Your Macs once start-up has settled. Start-up shows Your Macs while
 * the list loads and then, when this browser had a Mac chosen, restores that
 * Mac's workspace in the same step that finishes the list. So a Your Macs
 * heading next to "Loading your Macs…" says nothing about where start-up ends.
 */
async function goToYourMacs(page: Page) {
  const heading = page.getByRole('heading', { name: 'Your Macs', exact: true });
  // The loading panel and the list's live region both say it while the list loads.
  const listLoading = page.getByText(/^Loading your Macs/);
  const home = page.getByRole('button', { name: 'Go to home' });
  const onYourMacs = async () => (await heading.isVisible()) && (await listLoading.count()) === 0;
  await expect
    .poll(async () => (await onYourMacs()) || (await home.isEnabled()), { timeout: 25_000 })
    .toBe(true);
  if (!(await onYourMacs())) await home.click();
  await expect(heading).toBeVisible();
}

test('@device-management-account renames, inspects and removes a linked Mac, and the Mac stays refused', async ({ page, browser, baseURL }, testInfo) => {
  test.setTimeout(150_000);
  const hostLabel = requiredEnv('GT_LAB_HOST_LABEL');
  const newLabel = `Lab Mac ${Date.now().toString(36).slice(-6)}`;

  // This phone signs in with the Mac's one-time code: the account claims the lab Mac.
  const claimed = page.waitForResponse(
    (response) => response.url().includes('/account/claim-host-code') && response.request().method() === 'POST',
  );
  await signIn(page, requiredEnv('GT_LAB_LINK_CODE'));
  expect((await claimed).ok()).toBeTruthy();
  await openWorkspace(page);

  // A second phone on the same account has the Mac open when it is removed.
  const otherContext = await browser.newContext({ baseURL, viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  const other = await otherContext.newPage();
  try {
    await signIn(other);
    await expect(other.getByRole('heading', { name: 'Your Macs', exact: true })).toBeVisible({ timeout: 25_000 });
    await openWorkspace(other);

    await goToYourMacs(page);
    const menuFor = (label: string) => page.getByRole('button', { name: `More actions for ${label}`, exact: true });
    await expect(menuFor(hostLabel)).toBeVisible();

    // Rename: the account stores the new name, and the card shows it at once.
    await menuFor(hostLabel).click();
    await page.getByRole('menuitem', { name: 'Rename' }).click();
    const rename = page.getByRole('dialog', { name: 'Rename Mac' });
    const field = rename.getByLabel('Mac name');
    await expect(field).toHaveValue(hostLabel);
    await field.fill('');
    await rename.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(rename.getByRole('alert')).toHaveText('Enter a name.');
    await field.fill(newLabel);
    const renamed = page.waitForResponse(
      (response) => response.url().includes('/account/hosts/rename') && response.request().method() === 'POST',
    );
    await rename.getByRole('button', { name: 'Save', exact: true }).click();
    expect((await renamed).status()).toBe(200);
    await expect(rename).toHaveCount(0);
    await expect(page.getByText(`Renamed to ${newLabel}.`, { exact: true })).toBeVisible();
    await expect(page.getByRole('heading', { name: newLabel, exact: true })).toBeVisible();
    await page.screenshot({ path: testInfo.outputPath('renamed-mac.png'), fullPage: true });

    // The name is the account's, not this page's: it is still there after a reload.
    await page.reload();
    await goToYourMacs(page);
    await expect(page.getByRole('heading', { name: newLabel, exact: true })).toBeVisible({ timeout: 20_000 });
    await expect(page.getByRole('heading', { name: hostLabel, exact: true })).toHaveCount(0);

    // Details: read-only facts and the short device ID.
    await menuFor(newLabel).click();
    await page.getByRole('menuitem', { name: 'Details' }).click();
    const details = page.getByRole('dialog', { name: newLabel });
    await expect(details.getByText('Status', { exact: true })).toBeVisible();
    await expect(details.getByText('Online', { exact: true })).toBeVisible();
    await expect(details.getByText('Added', { exact: true })).toBeVisible();
    const deviceId = await details.locator('code').getAttribute('title');
    expect(deviceId).toBeTruthy();
    await expect(details.locator('code')).toHaveText(deviceId!.slice(0, 12));
    await page.screenshot({ path: testInfo.outputPath('mac-details.png'), fullPage: true });
    await details.getByRole('button', { name: 'Done', exact: true }).click();
    await expect(details).toHaveCount(0);
    await expect(menuFor(newLabel)).toBeFocused();

    // The Mac as this browser knew it, to try opening it again after the removal.
    const removedHost = await page.evaluate(async (id) => {
      // Development-only state read; it holds no tokens or private keys.
      const modulePath = '/src/lib/store.ts';
      const { useAppStore } = await import(/* @vite-ignore */ modulePath);
      return useAppStore.getState().availableHosts.find((host: { deviceId: string }) => host.deviceId === id);
    }, deviceId);
    expect(removedHost?.deviceId).toBe(deviceId);

    // Remove: confirmed first, then gone from the account.
    await menuFor(newLabel).click();
    await page.getByRole('menuitem', { name: 'Remove from account' }).click();
    const confirm = page.getByRole('alertdialog', { name: `Remove ${newLabel}?` });
    await expect(confirm).toContainText(
      'Phones and browsers signed in to this account lose access to this Mac right away.',
    );
    const removed = page.waitForResponse(
      (response) => response.url().includes('/account/hosts/remove') && response.request().method() === 'POST',
    );
    await confirm.getByRole('button', { name: 'Remove Mac', exact: true }).click();
    expect((await removed).status()).toBe(200);
    await expect(confirm).toHaveCount(0);
    await expect(page.getByText(`Removed ${newLabel} from your account.`, { exact: true })).toBeVisible();
    await expect(page.getByRole('heading', { name: newLabel, exact: true })).toHaveCount(0);
    // This page removed it: no second notice about it.
    await expect(page.getByText('This Mac was removed from your account.', { exact: true })).toHaveCount(0);
    await page.screenshot({ path: testInfo.outputPath('removed-mac.png'), fullPage: true });

    // The other phone loses the Mac at once and is told why.
    await expect(other.getByText('This Mac was removed from your account.', { exact: true })).toBeVisible({ timeout: 20_000 });
    await expect(other.getByRole('heading', { name: 'Your Macs', exact: true })).toBeVisible();
    await expect(other.getByRole('heading', { name: newLabel, exact: true })).toHaveCount(0);
    await other.screenshot({ path: testInfo.outputPath('other-phone-mac-removed.png'), fullPage: true });

    // Opening the old workspace is refused: the relay no longer admits this
    // browser to that Mac and sends none of its content.
    const relaySockets: RelaySocketRecord[] = [];
    page.on('websocket', (socket) => {
      if (!/\/relay\?/.test(socket.url())) return;
      const record: RelaySocketRecord = { frames: [], closed: false };
      relaySockets.push(record);
      socket.on('framereceived', ({ payload }) => {
        try {
          record.frames.push(String(JSON.parse(String(payload)).type));
        } catch {
          // Binary frames carry no type.
        }
      });
      socket.on('close', () => {
        record.closed = true;
      });
    });
    await page.evaluate(async (host) => {
      const modulePath = '/src/lib/store.ts';
      const { useAppStore } = await import(/* @vite-ignore */ modulePath);
      useAppStore.setState({ availableHosts: [host] });
      await useAppStore.getState().chooseHost(host.deviceId).catch(() => undefined);
    }, removedHost);
    await expect.poll(() => relaySockets.filter((socket) => socket.closed).length, { timeout: 20_000 }).toBeGreaterThan(0);
    const frames = relaySockets.flatMap((socket) => socket.frames);
    for (const type of ['auth_ok', 'relay_hello', 'relay_agent_state', 'relay_remote_apps']) {
      expect(frames, `the relay must not send ${type} for a removed Mac`).not.toContain(type);
    }
    const afterAttempt = await page.evaluate(async () => {
      const modulePath = '/src/lib/store.ts';
      const { useAppStore } = await import(/* @vite-ignore */ modulePath);
      const state = useAppStore.getState();
      const outcome = {
        online: state.relayHostOnline as boolean | null,
        agents: Object.keys(state.agents).length,
        hello: state.hostHello !== null,
      };
      // Stop the reconnect attempts this check started.
      await state.forgetCurrentMac();
      return outcome;
    });
    expect(afterAttempt.online).not.toBe(true);
    expect(afterAttempt).toMatchObject({ agents: 0, hello: false });

    // After a reload the account lists no Mac and offers to add one.
    await page.reload();
    await goToYourMacs(page);
    await expect(page.getByRole('button', { name: 'Add this Mac', exact: true })).toBeVisible({ timeout: 20_000 });
    await expect(page.getByRole('button', { name: /^More actions for / })).toHaveCount(0);
  } finally {
    await otherContext.close().catch((error) => {
      if (testInfo.status !== 'timedOut') throw error;
    });
  }
});
