import { expect, test } from '@playwright/test';

test('@fixture host selection states render and Refresh reports completion', async ({ page }) => {
  await page.goto('/?gtFixture=hosts-mixed');

  await expect(page.getByRole('heading', { name: 'Your Macs' })).toBeVisible();
  await expect(page.getByText("Test Mac")).toBeVisible();
  await expect(page.getByText('MacBook Pro')).toBeVisible();
  await expect(page.getByText('Offline', { exact: true })).toBeVisible();

  await page.getByRole('button', { name: 'Refresh', exact: true }).click();
  await expect(page.getByText('Macs updated.', { exact: true })).toBeVisible();
});

test('@fixture Terminal running state is usable at the current viewport', async ({ page }) => {
  await page.goto('/?gtFixture=workspace-terminal-running');

  const composer = page.getByPlaceholder('Type a terminal command...').filter({ visible: true });
  await expect(composer).toBeVisible();
  await expect(
    page.getByText('running command', { exact: true }).filter({ visible: true }).first(),
  ).toBeVisible();
  await expect(
    page.getByRole('button', { name: 'Start a new Terminal session' }).filter({ visible: true }),
  ).toBeVisible();

  const dimensions = await page.evaluate(() => ({
    viewport: document.documentElement.clientWidth,
    content: document.documentElement.scrollWidth,
  }));
  expect(dimensions.content).toBeLessThanOrEqual(dimensions.viewport + 1);
});

test('@fixture unverified Codex target stays retryable and blocks prompts', async ({ page }) => {
  await page.goto('/?gtFixture=workspace-codex-target-unverified');

  const openChat = page.getByRole('button', { name: 'Open chat: Glasstunnel 1' });
  await expect(openChat).toBeEnabled();
  await expect(openChat).toContainText('Open this chat');
  await expect(page.locator('textarea[placeholder="Send a prompt..."]:visible')).toBeDisabled();
});
