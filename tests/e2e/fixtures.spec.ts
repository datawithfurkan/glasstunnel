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

test('@fixture Your Macs never shows a loading or failed list as an account without Macs', async ({ page }) => {
  const addThisMac = page.getByRole('button', { name: 'Add this Mac', exact: true });

  await page.goto('/?gtFixture=hosts-loading');
  await expect(page.getByRole('heading', { name: 'Your Macs', exact: true })).toBeVisible();
  // The list container is busy, and one persistent polite live region says so.
  const busyList = page.locator('[aria-busy="true"]').filter({ hasText: 'Loading your Macs…' });
  await expect(busyList).toBeVisible();
  const announcement = page.getByRole('status').filter({ hasText: 'Loading your Macs…' });
  await expect(announcement).toHaveCount(1);
  await expect(announcement).toHaveAttribute('aria-live', 'polite');
  await expect(announcement).not.toHaveAttribute('aria-busy', 'true');
  await expect(addThisMac).toHaveCount(0);
  await expectNoHorizontalOverflow(page);

  await page.goto('/?gtFixture=hosts-error');
  const failure = page.getByRole('alert').filter({ hasText: 'Could not load your Macs' });
  await expect(failure).toBeVisible();
  await expect(page.getByText('Could not load your Macs', { exact: true })).toBeVisible();
  await expect(failure.getByRole('button', { name: 'Try again', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Refresh', exact: true })).toBeVisible();
  await expect(page.locator('[aria-busy="true"]').filter({ hasText: 'Could not load your Macs' })).toHaveCount(0);
  await expect(addThisMac).toHaveCount(0);
  await expectNoHorizontalOverflow(page);

  await page.goto('/?gtFixture=hosts-empty');
  await expect(addThisMac).toBeVisible();
  await expect(page.getByText('Loading your Macs…')).toHaveCount(0);
  await expect(page.getByRole('status').filter({ hasText: 'No Macs on this account yet.' })).toHaveCount(1);
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

// Device management: the "⋯" menu on each Mac in Your Macs. The fixture lists
// two Macs called "Studio Mac mini" (one online with a known app version, one
// offline without) and a MacBook Pro; Rename and Remove act on that list.
const STUDIO_MAC_MENU = 'More actions for Studio Mac mini';
const STUDIO_MAC_FINGERPRINT = 'gt-4a1b7e3ac';
const OFFLINE_STUDIO_MAC_FINGERPRINT = 'gt-9c03d5e81';

/** No scroller on the page (the document or a scrolling container inside it) scrolls sideways. */
async function expectNoSidewaysScroll(page: Page) {
  await expectNoHorizontalOverflow(page);
  const scrollers = await page.evaluate(() =>
    Array.from(document.querySelectorAll<HTMLElement>('body *'))
      .filter((element) => {
        const overflowX = getComputedStyle(element).overflowX;
        return (overflowX === 'auto' || overflowX === 'scroll') && element.scrollWidth > element.clientWidth + 1;
      })
      .map((element) => `${element.tagName.toLowerCase()}.${element.className}`.slice(0, 120)),
  );
  expect(scrollers, 'containers that scroll sideways').toEqual([]);
}

async function expectFocusInside(page: Page, selector: string) {
  const inside = await page.evaluate(
    (match) => document.activeElement instanceof HTMLElement && !!document.activeElement.closest(match),
    selector,
  );
  expect(inside, `focus should stay inside ${selector}`).toBe(true);
}

test('@fixture Mac actions menu opens from ⋯, moves by keyboard and closes on Escape or an outside tap', async ({ page }, testInfo) => {
  await page.goto('/?gtFixture=hosts-device-actions');
  await expect(page.getByRole('heading', { name: 'Your Macs', exact: true })).toBeVisible();

  const menuButtons = page.getByRole('button', { name: STUDIO_MAC_MENU, exact: true });
  await expect(menuButtons).toHaveCount(2);
  const more = menuButtons.first();
  await expectMinTapTarget(more, '⋯ button');
  await expect(more).toHaveAttribute('aria-haspopup', 'menu');
  await expect(more).toHaveAttribute('aria-expanded', 'false');
  // Two Macs with one name show a short device ID each.
  await expect(page.getByText(STUDIO_MAC_FINGERPRINT, { exact: true })).toBeVisible();
  await expect(page.getByText(OFFLINE_STUDIO_MAC_FINGERPRINT, { exact: true })).toBeVisible();
  await expectNoSidewaysScroll(page);

  await more.click();
  const menu = page.getByRole('menu');
  await expect(menu).toBeVisible();
  await expect(more).toHaveAttribute('aria-expanded', 'true');
  await expect(menu.getByRole('menuitem')).toHaveText(['Rename', 'Details', 'Remove from account']);
  for (const item of await menu.getByRole('menuitem').all()) await expectMinTapTarget(item, 'menu item');
  await expect(menu.getByRole('menuitem', { name: 'Rename' })).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(menu.getByRole('menuitem', { name: 'Details' })).toBeFocused();
  await page.keyboard.press('End');
  await expect(menu.getByRole('menuitem', { name: 'Remove from account' })).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(menu.getByRole('menuitem', { name: 'Rename' })).toBeFocused();
  await expectNoSidewaysScroll(page);
  await page.screenshot({ path: testInfo.outputPath('mac-actions-menu.png'), fullPage: true });

  await page.keyboard.press('Escape');
  await expect(menu).toHaveCount(0);
  await expect(more).toBeFocused();
  await expect(more).toHaveAttribute('aria-expanded', 'false');

  await more.click();
  await expect(menu).toBeVisible();
  await page.getByRole('heading', { name: 'Your Macs', exact: true }).click();
  await expect(menu).toHaveCount(0);
});

test('@fixture Rename checks the name, keeps focus inside, and shows the new name at once', async ({ page }, testInfo) => {
  await page.goto('/?gtFixture=hosts-device-actions');
  const more = page.getByRole('button', { name: STUDIO_MAC_MENU, exact: true }).first();

  // Cancel leaves the name as it was and returns focus to ⋯.
  await more.click();
  await page.getByRole('menuitem', { name: 'Rename' }).click();
  const dialog = page.getByRole('dialog', { name: 'Rename Mac' });
  await expect(dialog).toBeVisible();
  await dialog.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await expect(more).toBeFocused();

  await more.click();
  await page.getByRole('menuitem', { name: 'Rename' }).click();
  const field = dialog.getByLabel('Mac name');
  await expect(field).toHaveValue('Studio Mac mini');
  await expect(field).toBeFocused();
  for (let step = 0; step < 4; step += 1) {
    await page.keyboard.press('Tab');
    await expectFocusInside(page, '[role="dialog"]');
  }
  await page.keyboard.press('Shift+Tab');
  await expectFocusInside(page, '[role="dialog"]');
  await expectNoSidewaysScroll(page);
  await page.screenshot({ path: testInfo.outputPath('rename-mac-dialog.png'), fullPage: true });

  await field.fill('   ');
  await dialog.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(dialog.getByRole('alert')).toHaveText('Enter a name.');
  await expect(field).toHaveAttribute('aria-invalid', 'true');
  await field.fill('x'.repeat(41));
  await dialog.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(dialog.getByRole('alert')).toHaveText('Use 40 characters or fewer.');
  await page.screenshot({ path: testInfo.outputPath('rename-mac-invalid.png'), fullPage: true });

  await field.fill('Studio Mac mini (desk)');
  await expect(dialog.getByRole('alert')).toHaveCount(0);
  const save = dialog.getByRole('button', { name: 'Save', exact: true });
  await save.click();
  // The fixture answers after a short delay: the button says what is happening.
  await expect(dialog.getByRole('button', { name: 'Saving…', exact: true })).toBeDisabled();
  await expect(dialog).toHaveCount(0);
  await expect(page.getByText('Renamed to Studio Mac mini (desk).', { exact: true })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Studio Mac mini (desk)', exact: true })).toBeVisible();
  const renamed = page.getByRole('button', { name: 'More actions for Studio Mac mini (desk)', exact: true });
  await expect(renamed).toBeFocused();
  // The names differ now: no device IDs on the cards.
  await expect(page.getByText(STUDIO_MAC_FINGERPRINT, { exact: true })).toHaveCount(0);

  // Escape closes the dialog without saving.
  await renamed.click();
  await page.getByRole('menuitem', { name: 'Rename' }).click();
  await field.fill('Something else');
  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'Studio Mac mini (desk)', exact: true })).toBeVisible();
  await expect(renamed).toBeFocused();
});

test('@fixture Rename leaves out hidden characters, counts an emoji once and stores the composed name', async ({ page }) => {
  await page.goto('/?gtFixture=hosts-device-actions');
  const menuButtons = page.getByRole('button', { name: STUDIO_MAC_MENU, exact: true });
  const dialog = page.getByRole('dialog', { name: 'Rename Mac' });
  const field = dialog.getByLabel('Mac name');
  const save = dialog.getByRole('button', { name: 'Save', exact: true });

  await menuButtons.first().click();
  await page.getByRole('menuitem', { name: 'Rename' }).click();
  // A pasted zero-width space or direction override never reaches the field.
  await field.fill('Desk​ Mac‮ mini⁦');
  await expect(field).toHaveValue('Desk Mac mini');
  // Forty emoji are forty characters, though each takes two UTF-16 units.
  const desktop = '\u{1F5A5}';
  await field.fill(desktop.repeat(41));
  await save.click();
  await expect(dialog.getByRole('alert')).toHaveText('Use 40 characters or fewer.');
  await field.fill(desktop.repeat(40));
  await save.click();
  await expect(dialog).toHaveCount(0);
  await expect(page.getByRole('heading', { name: desktop.repeat(40), exact: true })).toBeVisible();

  // "e" and a combining accent are saved as one composed "é".
  const emojiMenu = page.getByRole('button', { name: `More actions for ${desktop.repeat(40)}`, exact: true });
  await emojiMenu.click();
  await page.getByRole('menuitem', { name: 'Rename' }).click();
  await field.fill('Zoé Mac');
  await save.click();
  await expect(dialog).toHaveCount(0);
  const composedMenu = page.getByRole('button', { name: 'More actions for Zoé Mac', exact: true });
  await expect(composedMenu).toBeVisible();
  expect(await composedMenu.getAttribute('aria-label')).toBe('More actions for Zoé Mac');

  // A name typed decomposed and in another case still reads as the same name:
  // both cards show their short device IDs again.
  await menuButtons.first().click();
  await page.getByRole('menuitem', { name: 'Rename' }).click();
  await field.fill('zoé mac');
  await save.click();
  await expect(dialog).toHaveCount(0);
  await expect(page.getByText(STUDIO_MAC_FINGERPRINT, { exact: true })).toBeVisible();
  await expect(page.getByText(OFFLINE_STUDIO_MAC_FINGERPRINT, { exact: true })).toBeVisible();
});

test('@fixture Details lists status, dates, app version and a copyable device ID', async ({ page }, testInfo) => {
  await page.goto('/?gtFixture=hosts-device-actions');
  const menuButtons = page.getByRole('button', { name: STUDIO_MAC_MENU, exact: true });

  await menuButtons.first().click();
  await page.getByRole('menuitem', { name: 'Details' }).click();
  const details = page.getByRole('dialog', { name: 'Studio Mac mini' });
  await expect(details).toBeVisible();
  for (const label of ['Status', 'Last seen', 'Added', 'Mac app version', 'Device ID']) {
    await expect(details.getByText(label, { exact: true })).toBeVisible();
  }
  await expect(details.getByText('Online', { exact: true })).toBeVisible();
  await expect(details.getByText('0.1.10', { exact: true })).toBeVisible();
  await expect(details.getByText(STUDIO_MAC_FINGERPRINT, { exact: true })).toBeVisible();
  await expectNoSidewaysScroll(page);
  await page.screenshot({ path: testInfo.outputPath('mac-details-dialog.png'), fullPage: true });

  const copy = details.getByRole('button', { name: 'Copy device ID' });
  await expectMinTapTarget(copy, 'copy device ID button');
  await copy.click();
  // Clipboard access depends on the browser; without it the full ID shows to copy by hand.
  await expect(copy.filter({ hasText: 'Copied' }).or(details.getByRole('textbox', { name: 'Full device ID' }))).toBeVisible();

  await details.getByRole('button', { name: 'Done', exact: true }).click();
  await expect(details).toHaveCount(0);
  await expect(menuButtons.first()).toBeFocused();

  // The offline Mac without a reported version has no version row; a tap outside closes.
  await menuButtons.nth(1).click();
  await page.getByRole('menuitem', { name: 'Details' }).click();
  await expect(details.getByText('Offline', { exact: true })).toBeVisible();
  await expect(details.getByText('Mac app version', { exact: true })).toHaveCount(0);
  await expect(details.getByText(OFFLINE_STUDIO_MAC_FINGERPRINT, { exact: true })).toBeVisible();
  await page.getByTestId('dialog-backdrop').click({ position: { x: 8, y: 8 } });
  await expect(details).toHaveCount(0);
});

test('@fixture Remove asks first and the Mac leaves the list only after Remove Mac', async ({ page }, testInfo) => {
  await page.goto('/?gtFixture=hosts-device-actions');
  const offlineMenu = page.getByRole('button', { name: STUDIO_MAC_MENU, exact: true }).nth(1);

  await offlineMenu.click();
  await page.getByRole('menuitem', { name: 'Remove from account' }).click();
  const confirm = page.getByRole('alertdialog', { name: 'Remove Studio Mac mini?' });
  await expect(confirm).toBeVisible();
  await expect(confirm).toContainText(
    'Phones and browsers signed in to this account lose access to this Mac right away. The Mac is signed out of your account. To use it again, link it from the Mac.',
  );
  await expect(confirm.getByRole('button', { name: 'Cancel', exact: true })).toBeFocused();
  await expectNoSidewaysScroll(page);
  await page.screenshot({ path: testInfo.outputPath('remove-mac-dialog.png'), fullPage: true });

  await confirm.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(confirm).toHaveCount(0);
  await expect(page.getByRole('button', { name: STUDIO_MAC_MENU, exact: true })).toHaveCount(2);

  await offlineMenu.click();
  await page.getByRole('menuitem', { name: 'Remove from account' }).click();
  await confirm.getByRole('button', { name: 'Remove Mac', exact: true }).click();
  await expect(confirm.getByRole('button', { name: 'Removing…', exact: true })).toBeDisabled();
  // Nothing leaves the list before the answer.
  await expect(page.getByRole('button', { name: STUDIO_MAC_MENU, exact: true })).toHaveCount(2);
  await expect(confirm).toHaveCount(0);
  await expect(page.getByText('Removed Studio Mac mini from your account.', { exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: STUDIO_MAC_MENU, exact: true })).toHaveCount(1);
  await expect(page.getByText(OFFLINE_STUDIO_MAC_FINGERPRINT, { exact: true })).toHaveCount(0);
  await expect(page.getByRole('status').filter({ hasText: '2 Macs listed.' })).toHaveCount(1);
  await expectNoSidewaysScroll(page);
  await page.screenshot({ path: testInfo.outputPath('remove-mac-done.png'), fullPage: true });
});

test('@fixture device-management fixtures open the menu and each dialog for screenshots', async ({ page }, testInfo) => {
  const views = [
    ['hosts-device-menu', page.getByRole('menu')],
    ['hosts-device-rename', page.getByRole('dialog', { name: 'Rename Mac' })],
    ['hosts-device-details', page.getByRole('dialog', { name: 'Studio Mac mini' })],
    ['hosts-device-remove', page.getByRole('alertdialog', { name: 'Remove Studio Mac mini?' })],
  ] as const;
  for (const [fixture, view] of views) {
    await page.goto(`/?gtFixture=${fixture}`);
    await expect(view).toBeVisible();
    await expectNoSidewaysScroll(page);
    await page.screenshot({ path: testInfo.outputPath(`${fixture}.png`), fullPage: true });
  }
});

test('@fixture Mac cards keep a 40-character name and the ⋯ button inside a 375px screen', async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 375, height: 812 });
  await page.goto('/?gtFixture=hosts-device-actions');
  const more = page.getByRole('button', { name: STUDIO_MAC_MENU, exact: true }).first();
  await more.click();
  await page.getByRole('menuitem', { name: 'Rename' }).click();
  const longName = 'W'.repeat(40);
  await page.getByRole('dialog', { name: 'Rename Mac' }).getByLabel('Mac name').fill(longName);
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  const renamed = page.getByRole('button', { name: `More actions for ${longName}`, exact: true });
  await expect(renamed).toBeVisible();
  await expectNoSidewaysScroll(page);
  await expectMinTapTarget(renamed, '⋯ button with a long name');
  const box = await renamed.boundingBox();
  expect(box!.x + box!.width).toBeLessThanOrEqual(375);
  await renamed.click();
  const menuBox = await page.getByRole('menu').boundingBox();
  expect(menuBox!.x).toBeGreaterThanOrEqual(0);
  expect(menuBox!.x + menuBox!.width).toBeLessThanOrEqual(375);
  await page.screenshot({ path: testInfo.outputPath('long-name-375.png'), fullPage: true });
});
