import { expect, test, type Locator, type Page } from '@playwright/test';

async function expectNoHorizontalOverflow(page: Page) {
  const dimensions = await page.evaluate(() => ({
    viewport: document.documentElement.clientWidth,
    content: document.documentElement.scrollWidth,
  }));
  expect(dimensions.content).toBeLessThanOrEqual(dimensions.viewport + 1);
}

async function expectMinTapTarget(locator: Locator, label: string) {
  const box = await locator.boundingBox();
  expect(box, `${label} should have a rendered box`).not.toBeNull();
  expect(box!.width, `${label} width`).toBeGreaterThanOrEqual(44);
  expect(box!.height, `${label} height`).toBeGreaterThanOrEqual(44);
}

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

  await expectNoHorizontalOverflow(page);
});

test('@fixture unverified Codex target stays retryable and blocks prompts', async ({ page }) => {
  await page.goto('/?gtFixture=workspace-codex-target-unverified');

  const openChat = page.getByRole('button', { name: 'Open chat: Glasstunnel 1' });
  await expect(openChat).toBeEnabled();
  await expect(openChat).toContainText('Open this chat');
  await expect(page.locator('textarea[placeholder="Send a prompt..."]:visible')).toBeDisabled();
});

test('@fixture mobile viewport allows user zoom', async ({ page }) => {
  await page.setViewportSize({ width: 393, height: 852 });
  await page.goto('/?gtFixture=workspace-all-apps');

  const viewportContent = await page.locator('meta[name="viewport"]').getAttribute('content');
  expect(viewportContent).toContain('width=device-width');
  expect(viewportContent).not.toContain('user-scalable=no');
  expect(viewportContent).not.toContain('maximum-scale=1');
});

test('@fixture mobile app strip exposes overflow and remains reachable', async ({ page }) => {
  await page.setViewportSize({ width: 393, height: 852 });
  await page.goto('/?gtFixture=workspace-all-apps');

  const strip = page.locator('[aria-label="Coding apps"]').first();
  await expect(strip).toBeVisible();

  const overflows = await strip.evaluate((element) => element.scrollWidth > element.clientWidth + 1);
  if (!overflows) return;

  const right = page.getByRole('button', { name: 'Scroll Coding apps right' });
  await expect(right).toBeVisible();
  await expectMinTapTarget(right, 'coding apps scroll-right button');

  await right.click();
  await expect(page.getByRole('button', { name: 'OpenCode' })).toBeVisible();
});

test('@fixture mobile primary controls meet the 44px tap target', async ({ page }) => {
  await page.setViewportSize({ width: 393, height: 852 });
  await page.goto('/?gtFixture=workspace-terminal-running');

  await expectMinTapTarget(page.getByRole('button', { name: 'Back to projects' }), 'back button');
  await expectMinTapTarget(page.getByRole('button', { name: 'Start a new Terminal session' }), 'new terminal button');
  await expectMinTapTarget(page.getByRole('button', { name: 'Rename Terminal session' }), 'rename terminal button');
  await expectMinTapTarget(page.getByRole('button', { name: 'Close Terminal session' }), 'close terminal button');
  await expectMinTapTarget(
    page.getByRole('button', { name: /^(Run command|Stop response)$/ }),
    'composer primary button',
  );
});

test('@fixture mobile composer stays reachable on short keyboard-like viewport', async ({ page }) => {
  await page.setViewportSize({ width: 393, height: 520 });
  await page.goto('/?gtFixture=workspace-terminal-running');

  const composer = page.getByPlaceholder('Type a terminal command...').filter({ visible: true });
  await expect(composer).toBeVisible();
  await composer.click();

  const box = await composer.boundingBox();
  expect(box).not.toBeNull();
  expect(box!.y + box!.height).toBeLessThanOrEqual(520);
  await expectNoHorizontalOverflow(page);
});

test('@fixture mobile command surface shows one status badge', async ({ page }) => {
  await page.setViewportSize({ width: 393, height: 852 });
  await page.goto('/?gtFixture=workspace-terminal-running');

  const width = page.viewportSize()?.width ?? 0;
  const frameStatus = page.locator('[data-testid="terminal-frame-status"]').filter({ visible: true });
  if (width < 768) {
    await expect(frameStatus).toHaveCount(0);
  } else {
    await expect(frameStatus).toHaveCount(1);
  }
});
