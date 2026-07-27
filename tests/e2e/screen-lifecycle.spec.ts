import { expect, test, type Page } from '@playwright/test';

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for the local screen test.`);
  return value;
}

async function signInAndLinkHost(page: Page): Promise<void> {
  const email = requiredEnv('GT_LAB_EMAIL');
  const password = requiredEnv('GT_LAB_PASSWORD');
  const linkCode = requiredEnv('GT_LAB_LINK_CODE');
  const hostLabel = requiredEnv('GT_LAB_HOST_LABEL');

  await page.goto(`/?authProvider=email&linkCode=${encodeURIComponent(linkCode)}`);
  await expect(page.getByRole('heading', { name: 'Open your agents' })).toBeVisible();
  await page.getByPlaceholder('you@example.com').fill(email);
  await page.getByRole('button', { name: 'Continue with email', exact: true }).click();
  await page.getByPlaceholder('Enter your password').fill(password);

  const claimResponse = page.waitForResponse(
    (response) =>
      response.url().includes('/account/claim-host-code') && response.request().method() === 'POST',
  );
  await page.getByRole('button', { name: 'Sign in', exact: true }).last().click();
  await expect((await claimResponse).ok()).toBeTruthy();
  await expect(
    page.getByText(hostLabel, { exact: true }).filter({ visible: true }).first(),
  ).toBeVisible({ timeout: 20_000 });
}

async function decodedSvg(page: Page, screen: ReturnType<Page['getByRole']>): Promise<string> {
  const source = await screen.getAttribute('src');
  if (!source?.startsWith('data:image/svg+xml;base64,')) return '';
  return page.evaluate((value) => atob(value.split(',', 2)[1] ?? ''), source);
}

test('@screen renders changing frames through start, quality, stop, restart, and refresh', async ({
  page,
}) => {
  await signInAndLinkHost(page);
  await page
    .getByRole('button', { name: 'Screen', exact: true })
    .filter({ visible: true })
    .first()
    .click();

  await expect(page.getByRole('heading', { name: 'Mac Screen' })).toBeVisible();
  const sharingSwitch = page.getByRole('switch').filter({ visible: true });
  await expect(sharingSwitch).toHaveAttribute('aria-checked', 'false');
  await sharingSwitch.click();

  const screen = page.getByRole('img', { name: 'Mac screen' });
  await expect(screen).toBeVisible({ timeout: 20_000 });
  await expect(page.getByText('Screen ready', { exact: true }).filter({ visible: true })).toBeVisible();
  const firstFrame = await screen.getAttribute('src');
  await expect.poll(() => screen.getAttribute('src')).not.toBe(firstFrame);
  await expect(screen).toHaveAttribute('width', '640');

  await screen.click();
  await expect.poll(() => decodedSvg(page, screen)).toContain('Pointers 1 0.500 0.500 click');
  await page.waitForTimeout(600);
  expect(await decodedSvg(page, screen)).toContain('Pointers 1 0.500 0.500 click');

  await page.getByRole('button', { name: 'Fast', exact: true }).click();
  await expect(screen).toHaveAttribute('width', '320', { timeout: 20_000 });
  await expect(page.getByText('Screen ready', { exact: true }).filter({ visible: true })).toBeVisible();

  await sharingSwitch.click();
  await expect(sharingSwitch).toHaveAttribute('aria-checked', 'false');
  await expect(screen).toBeHidden({ timeout: 20_000 });
  await expect(
    page.getByRole('heading', { name: 'Screen sharing off', exact: true }),
  ).toBeVisible();

  await sharingSwitch.click();
  await expect(screen).toBeVisible({ timeout: 20_000 });
  await expect(screen).toHaveAttribute('width', '320');

  const frameBeforeRefresh = await screen.getAttribute('src');

  await page.reload();
  await page
    .getByRole('button', { name: 'Screen', exact: true })
    .filter({ visible: true })
    .first()
    .click();
  await expect(page.getByRole('heading', { name: 'Mac Screen' })).toBeVisible({ timeout: 20_000 });
  const reconnectedScreen = page.getByRole('img', { name: 'Mac screen' });
  await expect(reconnectedScreen).toBeVisible({ timeout: 20_000 });
  await expect.poll(() => reconnectedScreen.getAttribute('src')).not.toBe(frameBeforeRefresh);

  await page.getByRole('switch').filter({ visible: true }).click();
  await expect(reconnectedScreen).toBeHidden({ timeout: 20_000 });
});
