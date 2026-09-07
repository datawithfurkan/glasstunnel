import { expect, test } from '@playwright/test';

test('@retention-account offline copies expire, clear and recover with a real local account', async ({ page }, testInfo) => {
  test.setTimeout(90_000);
  let blockRelay = false;
  await page.routeWebSocket(/\/relay\?/, (route) => {
    if (blockRelay) route.close({ code: 1013, reason: 'Local offline test' });
    else route.connectToServer();
  });
  await page.goto(`/?authProvider=email&linkCode=${encodeURIComponent(process.env.GT_LAB_LINK_CODE!)}`);
  await page.getByPlaceholder('you@example.com').fill(process.env.GT_LAB_EMAIL!);
  await page.getByRole('button', { name: 'Continue with email', exact: true }).click();
  await page.getByPlaceholder('Enter your password').fill(process.env.GT_LAB_PASSWORD!);
  await page.getByRole('button', { name: 'Sign in', exact: true }).last().click();
  const terminalTab = page.getByRole('button', { name: 'Terminal', exact: true }).filter({ visible: true }).first();
  const openMac = page.getByRole('button', { name: 'Open', exact: true }).first();
  await expect(terminalTab.or(openMac).first()).toBeVisible({ timeout: 25_000 });
  if (await openMac.isVisible()) await openMac.click();
  await expect(page.getByRole('button', { name: 'Terminal', exact: true }).filter({ visible: true }).first()).toBeVisible({ timeout: 25_000 });
  await page.getByRole('button', { name: 'Terminal', exact: true }).filter({ visible: true }).first().click();
  await page.getByRole('button', { name: 'Open Terminal', exact: true }).filter({ visible: true }).click();
  const composer = page.getByPlaceholder('Type a terminal command...').filter({ visible: true });
  await expect(composer).toBeEnabled({ timeout: 20_000 });
  await composer.fill("printf '%s%s\\n' 'RETENTION_' 'FIXTURE'");
  await page.getByRole('button', { name: 'Run command' }).filter({ visible: true }).click();
  await expect(page.locator('pre').filter({ hasText: 'RETENTION_FIXTURE', visible: true }).first()).toBeVisible();

  const cacheCounts = () => page.evaluate(async () => {
    const modulePath = '/node_modules/.vite/deps/idb-keyval.js';
    const { keys, get } = await import(/* @vite-ignore */ modulePath);
    const cacheKeys = (await keys()).filter((key: unknown) => typeof key === 'string' && key.startsWith('gt.relay.cache.v2.'));
    const copies = await Promise.all(cacheKeys.map((key: string) => get(key)));
    return { keys: cacheKeys.length, agents: copies.reduce((n: number, copy: { items: object }) => n + Object.keys(copy.items).filter((key) => key.startsWith('agent:')).length, 0), legacy: (await keys()).filter((key: unknown) => typeof key === 'string' && key.startsWith('gt.relay.cache.') && !key.startsWith('gt.relay.cache.v2.')).length };
  });
  await expect.poll(async () => (await cacheCounts()).agents).toBeGreaterThan(0);
  blockRelay = true;
  await page.reload();
  await expect(page.getByRole('button', { name: 'Terminal', exact: true }).filter({ visible: true }).first()).toBeVisible();
  await expect.poll(async () => page.evaluate(async () => {
    const modulePath = '/src/lib/store.ts';
    const { useAppStore } = await import(/* @vite-ignore */ modulePath);
    return useAppStore.getState().relayHostOnline;
  })).toBe(false);

  // Advance the browser clock only. Local auth/Worker/Swift processes keep their
  // real clocks; the focus event exercises production resume-time expiry.
  const realNow = Date.now();
  await page.clock.setFixedTime(realNow + 24 * 60 * 60_000 + 1000);
  await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await expect.poll(async () => (await cacheCounts()).agents).toBe(0);
  await expect.poll(async () => page.evaluate(async () => {
    const modulePath = '/src/lib/store.ts';
    const { useAppStore } = await import(/* @vite-ignore */ modulePath);
    return Object.keys(useAppStore.getState().agents).length;
  })).toBe(0);
  await page.screenshot({ path: testInfo.outputPath('expired-offline-workspace.png'), fullPage: true });

  await page.clock.setFixedTime(Date.now());
  blockRelay = false;
  await page.reload();
  await expect.poll(async () => (await cacheCounts()).agents, { timeout: 25_000 }).toBeGreaterThan(0);
  await page.getByRole('button', { name: 'Open menu' }).click();
  await page.getByRole('menuitem', { name: 'Profile Account details', exact: true }).click();
  blockRelay = true;
  await page.evaluate(async () => {
    const modulePath = '/src/lib/store.ts';
    const { useAppStore } = await import(/* @vite-ignore */ modulePath);
    useAppStore.getState().disconnectPeer();
  });
  await page.getByRole('button', { name: 'Clear offline copies', exact: true }).click();
  await expect(page.getByRole('status')).toContainText('Offline copies cleared from this browser');
  await expect.poll(async () => (await cacheCounts()).keys).toBe(0);
  await page.screenshot({ path: testInfo.outputPath('profile-cache-cleared.png'), fullPage: true });
  await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Open your agents' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Continue with email instead', exact: true })).toBeVisible();
  expect(await cacheCounts()).toEqual({ keys: 0, agents: 0, legacy: 0 });

  // Same browser profile, different real local account. No production API or
  // personal identity is used, and the secondary fixture is removed afterward.
  await page.goto('/?authProvider=email');
  await page.getByPlaceholder('you@example.com').fill(process.env.GT_LAB_SECOND_EMAIL!);
  await page.getByRole('button', { name: 'Continue with email', exact: true }).click();
  await page.getByPlaceholder('Enter your password').fill(process.env.GT_LAB_PASSWORD!);
  await page.getByRole('button', { name: 'Sign in', exact: true }).last().click();
  await expect(page.getByRole('heading', { name: 'Your Macs', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Open', exact: true })).toHaveCount(0);
  await expect(page.getByText('RETENTION_FIXTURE', { exact: true })).toHaveCount(0);
  expect(await cacheCounts()).toEqual({ keys: 0, agents: 0, legacy: 0 });
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Your Macs', exact: true })).toBeVisible();
  expect(await cacheCounts()).toEqual({ keys: 0, agents: 0, legacy: 0 });
});
