import { expect, test } from '@playwright/test';

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for the local account test.`);
  return value;
}

test('@account links a local host and controls recoverable Terminal sessions', async ({ page }) => {
  const email = requiredEnv('GT_LAB_EMAIL');
  const password = requiredEnv('GT_LAB_PASSWORD');
  const linkCode = requiredEnv('GT_LAB_LINK_CODE');
  const hostLabel = requiredEnv('GT_LAB_HOST_LABEL');
  const marker = `GT_E2E_${Date.now()}`;

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
  await page
    .getByRole('button', { name: 'Terminal', exact: true })
    .filter({ visible: true })
    .first()
    .click();
  await page
    .getByRole('button', { name: 'Open Terminal', exact: true })
    .filter({ visible: true })
    .click();
  const composer = page.getByPlaceholder('Type a terminal command...').filter({ visible: true });
  await expect(composer).toBeVisible({ timeout: 20_000 });

  await composer.fill(`printf '${marker}\\n'`);
  await page.getByRole('button', { name: 'Run command' }).filter({ visible: true }).click();
  await expect(page.locator('pre').filter({ hasText: marker, visible: true }).first()).toBeVisible({
    timeout: 20_000,
  });

  await composer.fill('sleep 20');
  await page.getByRole('button', { name: 'Run command' }).filter({ visible: true }).click();
  await page
    .getByRole('button', { name: 'Stop response' })
    .filter({ visible: true })
    .click({ timeout: 10_000 });

  const recoveryMarker = `${marker}_RECOVERED`;
  await expect(composer).toBeEnabled({ timeout: 10_000 });
  await composer.fill(`printf '${recoveryMarker}\\n'`);
  await page.getByRole('button', { name: 'Run command' }).filter({ visible: true }).click();
  await expect(
    page.locator('pre').filter({ hasText: recoveryMarker, visible: true }).first(),
  ).toBeVisible({ timeout: 20_000 });

  await page
    .getByRole('button', { name: 'Start a new Terminal session' })
    .filter({ visible: true })
    .click();
  await expect(
    page.getByText('Terminal 2', { exact: true }).filter({ visible: true }).first(),
  ).toBeVisible({ timeout: 20_000 });
  await page
    .getByRole('button', { name: 'Rename Terminal session' })
    .filter({ visible: true })
    .click();
  await page
    .getByRole('textbox', { name: 'Terminal session name' })
    .filter({ visible: true })
    .fill('E2E Terminal');
  await page.getByRole('button', { name: 'Save', exact: true }).filter({ visible: true }).click();
  await expect(
    page.getByText('E2E Terminal', { exact: true }).filter({ visible: true }).first(),
  ).toBeVisible({ timeout: 10_000 });

  await page
    .getByRole('button', { name: 'Close Terminal session' })
    .filter({ visible: true })
    .click();
  await expect(
    page.getByText('Default Terminal', { exact: true }).filter({ visible: true }).first(),
  ).toBeVisible({ timeout: 20_000 });
});
