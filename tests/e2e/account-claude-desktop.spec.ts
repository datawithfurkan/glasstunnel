import { expect, type Locator, type Page, test } from '@playwright/test';

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for the local Claude desktop account test.`);
  return value;
}

/** Title of the dedicated Claude app session the lane may type into. */
const sessionTitle = process.env.GT_LAB_CLAUDE_SESSION ?? 'Glasstunnel live evidence';

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

async function openTab(page: Page, label: string): Promise<void> {
  const tab = page.getByRole('button', { name: label, exact: true }).filter({ visible: true });
  await expect(tab).toBeVisible({ timeout: 30_000 });
  await tab.click();
}

async function startIfOffered(page: Page): Promise<void> {
  const start = page.getByRole('button', { name: 'Start', exact: true }).filter({ visible: true });
  if (await start.isVisible().catch(() => false)) await start.click();
}

async function occurrences(page: Page, text: string): Promise<number> {
  const body = await page.locator('main').filter({ visible: true }).first().innerText();
  return body.split(text).length - 1;
}

function responseReady(page: Page): Locator {
  // Shown in the card header and, on CLI cards, in the terminal frame too.
  return page.getByText('Response ready', { exact: true }).filter({ visible: true }).first();
}

async function sendPrompt(page: Page, prompt: string): Promise<void> {
  const composer = page.locator('textarea').filter({ visible: true });
  await expect(composer).toBeEnabled({ timeout: 60_000 });
  await composer.fill(prompt);
  await page.getByRole('button', { name: 'Send prompt' }).filter({ visible: true }).click();
}

async function decide(page: Page, choice: RegExp): Promise<void> {
  const card = page.getByText('Claude needs a decision', { exact: true }).filter({ visible: true });
  await expect(card).toBeVisible({ timeout: 120_000 });
  await page.getByRole('button', { name: choice }).filter({ visible: true }).first().click();
  await page.getByRole('button', { name: 'Continue', exact: true }).filter({ visible: true }).click();
  await expect(card).toBeHidden({ timeout: 60_000 });
}

/**
 * Drives the Claude desktop card from a phone-sized browser through the local
 * lab against the real Claude app: switches to a dedicated session, sends a
 * prompt that the Mac types into the app's composer via Accessibility, answers
 * a permission prompt and an AskUserQuestion from the phone, and checks that
 * the Claude Code CLI card started alongside never inherits the desktop
 * session's hook events. Costs three short turns on the signed-in account.
 */
test('@claude-desktop-account prompts, answers permission and question dialogs, and leaves the CLI card untouched', async ({
  page,
}) => {
  test.setTimeout(480_000);
  const marker = `GT_CLAUDE_APP_${Date.now()}`;

  await signInAndLinkHost(page);

  // The CLI card runs alongside so ownership can be checked at the end.
  await openTab(page, 'Code');
  await startIfOffered(page);
  await expect(page.locator('textarea').filter({ visible: true })).toBeEnabled({ timeout: 90_000 });

  await openTab(page, 'Claude');
  await startIfOffered(page);

  const current = page
    .getByRole('button', { name: `Current session: ${sessionTitle}`, exact: true })
    .filter({ visible: true });
  if (!(await current.isVisible().catch(() => false))) {
    const target = page
      .getByRole('button', { name: `Switch to ${sessionTitle}`, exact: true })
      .filter({ visible: true });
    await expect(target).toBeVisible({ timeout: 30_000 });
    await target.click();
  }
  await expect(current).toBeVisible({ timeout: 30_000 });

  // 1. Plain prompt: typed into the real composer, answered, Stop hook → "Response ready".
  await sendPrompt(page, `Reply with exactly ${marker} and nothing else.`);
  await expect(responseReady(page)).toBeVisible({ timeout: 150_000 });
  await expect.poll(() => occurrences(page, marker), { timeout: 30_000 }).toBeGreaterThanOrEqual(2);

  // 2. Permission prompt answered from the phone.
  const permissionMarker = `${marker}_PERM`;
  await sendPrompt(
    page,
    `Run this shell command with your Bash tool and show me its output: echo ${permissionMarker}`,
  );
  await decide(page, /Allow/);
  await expect(responseReady(page)).toBeVisible({ timeout: 150_000 });
  await expect
    .poll(() => occurrences(page, permissionMarker), { timeout: 30_000 })
    .toBeGreaterThanOrEqual(2);

  // 3. AskUserQuestion answered from the phone.
  await sendPrompt(
    page,
    'Use your AskUserQuestion tool to ask me one question with exactly two options labelled Alpha and Beta. After I answer, reply with only the label I picked followed by _PICKED.',
  );
  await decide(page, /Beta/);
  await expect(responseReady(page)).toBeVisible({ timeout: 150_000 });
  await expect.poll(() => occurrences(page, 'Beta_PICKED'), { timeout: 30_000 }).toBeGreaterThanOrEqual(1);

  // 4. The CLI card owns a different session, so none of the above moved it.
  await openTab(page, 'Code');
  await expect(responseReady(page)).toBeHidden();
  await expect(page.getByText('Claude needs a decision', { exact: true })).toBeHidden();
});
