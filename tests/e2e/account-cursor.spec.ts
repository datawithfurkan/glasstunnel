import { expect, type Page, test } from '@playwright/test';

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for the local Cursor desktop account test.`);
  return value;
}

/** Title of the dedicated Cursor chat the lane may type into. */
const chatTitle = process.env.GT_LAB_CURSOR_CHAT ?? 'Glasstunnel live evidence';

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

async function occurrences(page: Page, text: string): Promise<number> {
  const body = await page.locator('main').filter({ visible: true }).first().innerText();
  return body.split(text).length - 1;
}

async function turnFinished(page: Page, text: string, atLeast: number): Promise<void> {
  await expect.poll(() => occurrences(page, text), { timeout: 150_000 }).toBeGreaterThanOrEqual(atLeast);
  await expect(page.getByText('done', { exact: true }).filter({ visible: true }).first()).toBeVisible({
    timeout: 30_000,
  });
}

async function sendPrompt(page: Page, prompt: string): Promise<void> {
  const composer = page.locator('textarea').filter({ visible: true });
  await expect(composer).toBeEnabled({ timeout: 60_000 });
  await composer.fill(prompt);
  await page.getByRole('button', { name: /^Send( prompt)?$/ }).filter({ visible: true }).click();
}

/**
 * Drives the Cursor desktop card from a phone-sized browser through the local
 * lab against the real Cursor app: switches to a dedicated chat (the Mac
 * presses its sidebar entry and confirms the window shows it), sends a prompt
 * that the Mac types into the app's composer through Accessibility, watches
 * the turn finish through Cursor's hooks, and interrupts a long reply from
 * the phone through the app's Stop control. Costs two short turns on the
 * signed-in Cursor account; keep the dedicated chat on a cheap model.
 */
test('@cursor-desktop-account switches to a dedicated chat, prompts, and interrupts Cursor through the local relay', async ({
  page,
}) => {
  test.setTimeout(480_000);
  const marker = `GT_CURSOR_APP_${Date.now()}`;

  await signInAndLinkHost(page);

  const cursorTab = page.getByRole('button', { name: 'Cursor', exact: true }).filter({ visible: true });
  await expect(cursorTab).toBeVisible({ timeout: 30_000 });
  await cursorTab.click();

  // The card's body renders a moment after the tab switch (later on WebKit);
  // give the Start button time to appear before deciding it is not needed.
  const startButton = page.getByRole('button', { name: 'Start', exact: true }).filter({ visible: true });
  await startButton.waitFor({ state: 'visible', timeout: 15_000 }).catch(() => undefined);
  if (await startButton.isVisible().catch(() => false)) await startButton.click();

  // The card lists the app's chats; the dedicated one is either already in
  // front ("Current chat") or gets switched to. A switch the app has not
  // confirmed yet reads "Open chat" and is retried until the title matches.
  const current = page
    .getByRole('button', { name: `Current chat: ${chatTitle}`, exact: true })
    .filter({ visible: true });
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline && !(await current.isVisible().catch(() => false))) {
    const switchTo = page.getByRole('button', { name: `Switch to ${chatTitle}`, exact: true }).filter({ visible: true });
    const open = page.getByRole('button', { name: `Open chat: ${chatTitle}`, exact: true }).filter({ visible: true });
    if (await switchTo.isVisible().catch(() => false)) await switchTo.click();
    else if (await open.isVisible().catch(() => false)) await open.click();
    await page.waitForTimeout(2_000);
  }
  await expect(current).toBeVisible({ timeout: 30_000 });

  // 1. Plain prompt: typed into the real composer, answered; the stop hook
  //    ends the turn and the store supplies the reply text.
  await sendPrompt(page, `Reply with exactly ${marker} and nothing else.`);
  await turnFinished(page, marker, 2);

  // 2. Interrupt from the phone: the Mac presses the app's Stop control; the
  //    stop hook reports the turn as aborted and the closing marker never lands.
  const doneMarker = `${marker}_DONE`;
  await sendPrompt(
    page,
    `Count from 1 to 1500 in words, one number per line, without using any tools. After the last line, reply with exactly ${doneMarker}.`,
  );
  // The app's model can be fast: press Stop soon after the turn starts.
  const stop = page.getByRole('button', { name: 'Stop response', exact: true }).filter({ visible: true });
  await expect(stop).toBeVisible({ timeout: 60_000 });
  await page.waitForTimeout(1_500);
  // A fast model can finish the long reply before the click lands; a Stop
  // control that vanished then means the turn ended on its own, which is a
  // lane failure worth naming rather than a silent hang until the test timeout.
  await stop.click({ timeout: 15_000 }).catch(async () => {
    throw new Error(`the Stop control disappeared before it could be pressed; the card shows ${await page.locator('main').filter({ visible: true }).first().innerText().then((t) => t.slice(-300))}`);
  });
  await expect(page.getByText('idle', { exact: true }).filter({ visible: true }).first()).toBeVisible({
    timeout: 90_000,
  });
  await expect(page.getByText(/^Stopped/).filter({ visible: true }).first()).toBeVisible({
    timeout: 30_000,
  });
  expect(await occurrences(page, doneMarker), 'the interrupted reply never reached its closing marker').toBe(1);
  await expect(page.locator('textarea').filter({ visible: true })).toBeEnabled({ timeout: 30_000 });
});
