import { expect, test } from '@playwright/test';

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for the signed screen test.`);
  return value;
}

test('@signed-screen controls real signed Mac capture locally', async ({ page }) => {
  test.skip(
    process.env.GT_LAB_SIGNED_SCREEN !== '1',
    'Explicit opt-in is required because this test captures the real Mac display.',
  );
  test.setTimeout(120_000);

  await page.goto('/?authProvider=email');
  await expect(page.getByRole('heading', { name: 'Open your agents' })).toBeVisible();
  await page.getByPlaceholder('you@example.com').fill(requiredEnv('GT_LAB_EMAIL'));
  await page.getByRole('button', { name: 'Continue with email', exact: true }).click();
  await page.getByPlaceholder('Enter your password').fill(requiredEnv('GT_LAB_PASSWORD'));
  await page.getByRole('button', { name: 'Sign in', exact: true }).last().click();

  await expect(page.getByRole('heading', { name: 'Your Macs' })).toBeVisible({ timeout: 20_000 });
  const hostLabel = requiredEnv('GT_LAB_SIGNED_HOST_LABEL');
  const onlineMac = page
    .locator('article')
    .filter({ hasText: hostLabel })
    .filter({ hasText: 'Online' });
  await expect(onlineMac).toBeVisible({ timeout: 20_000 });
  await onlineMac.getByRole('button', { name: /^(Connect|Open)$/ }).click();

  const openScreen = async () => {
    await page
      .getByRole('button', { name: 'Screen', exact: true })
      .filter({ visible: true })
      .first()
      .click();
    await expect(page.getByRole('heading', { name: 'Mac Screen' })).toBeVisible({
      timeout: 20_000,
    });
  };

  await openScreen();
  let sharingSwitch = page.getByRole('switch').filter({ visible: true });
  if ((await sharingSwitch.getAttribute('aria-checked')) === 'false') {
    await sharingSwitch.click();
  }

  let screen = page.getByRole('img', { name: 'Mac screen' });
  await expect(screen).toBeVisible({ timeout: 30_000 });
  await expect(page.getByText('Screen ready', { exact: true }).filter({ visible: true })).toBeVisible();
  await expect(screen).toHaveAttribute('width', /\d+/);

  await page.getByRole('button', { name: 'Fast', exact: true }).click();
  await expect(page.getByText('Screen ready', { exact: true }).filter({ visible: true })).toBeVisible({
    timeout: 30_000,
  });

  await sharingSwitch.click();
  await expect(screen).toBeHidden({ timeout: 30_000 });
  await sharingSwitch.click();
  await expect(screen).toBeVisible({ timeout: 30_000 });

  await page.reload();
  await openScreen();
  screen = page.getByRole('img', { name: 'Mac screen' });
  await expect(screen).toBeVisible({ timeout: 30_000 });
  sharingSwitch = page.getByRole('switch').filter({ visible: true });
  await sharingSwitch.click();
  await expect(screen).toBeHidden({ timeout: 30_000 });
});
