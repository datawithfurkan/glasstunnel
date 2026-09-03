import { expect, type Page, test } from '@playwright/test';

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for the local Cursor Agent account test.`);
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

async function occurrences(page: Page, text: string): Promise<number> {
  const body = await page.locator('main').filter({ visible: true }).first().innerText();
  return body.split(text).length - 1;
}

/**
 * A chat-style card shows the status pill next to its title; a finished turn
 * is recognised by the reply text landing in the transcript and the pill
 * reading "done".
 */
async function turnFinished(page: Page, text: string, atLeast: number): Promise<void> {
  await expect.poll(() => occurrences(page, text), { timeout: 120_000 }).toBeGreaterThanOrEqual(atLeast);
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
 * Drives the Cursor Agent card from a phone-sized browser through the local
 * lab: the Mac runs the real `cursor-agent` CLI headlessly on the nano model,
 * a prompt is answered end to end, a plan-mode read produces a tool row, and
 * a long reply is interrupted from the phone. Costs three short turns on the
 * signed-in Cursor account.
 */
test('@cursor-agent-account prompts, reads a file in plan mode, and interrupts Cursor Agent through the local relay', async ({
  page,
}) => {
  test.setTimeout(420_000);
  const marker = `GT_CURSOR_AGENT_${Date.now()}`;

  await signInAndLinkHost(page);

  const agentTab = page.getByRole('button', { name: 'Agent', exact: true }).filter({ visible: true });
  await expect(agentTab).toBeVisible({ timeout: 30_000 });
  await agentTab.click();

  const startButton = page.getByRole('button', { name: 'Start', exact: true }).filter({ visible: true });
  if (await startButton.isVisible().catch(() => false)) await startButton.click();

  // The card lists the CLI's chats plus a "New chat" row once the Mac has
  // read the store; "ready" means the CLI is present and a chat is selected.
  await expect(
    page.getByRole('button', { name: /New chat/ }).filter({ visible: true }).first(),
  ).toBeVisible({ timeout: 90_000 });
  await expect(page.getByText('ready', { exact: true }).filter({ visible: true }).first()).toBeVisible({
    timeout: 30_000,
  });

  // 1. Plain prompt on the nano model: the reply carries the marker.
  await sendPrompt(page, `Reply with exactly ${marker} and nothing else.`);
  await turnFinished(page, marker, 2);

  // 2. Plan mode is read-only; a file read shows up as a tool row titled with
  //    the file, and the reply carries what it found.
  await sendPrompt(page, '/mode plan');
  await expect(page.getByText('Mode: plan', { exact: true }).filter({ visible: true }).first()).toBeVisible({
    timeout: 20_000,
  });
  await sendPrompt(
    page,
    'Use your file reading tool to read package.json at the root of this workspace, then reply with only the value of its "name" field.',
  );
  await turnFinished(page, 'glasstunnel', 1);
  const readRow = page.locator('.gt-tool-row', { hasText: 'package.json' }).filter({ visible: true }).last();
  await expect(readRow).toBeVisible({ timeout: 30_000 });

  // 3. Interrupt from the phone: a long reply is stopped, the transcript
  //    records the turn as stopped, and the closing marker never lands.
  await sendPrompt(page, '/mode ask');
  await expect(page.getByText('Mode: ask', { exact: true }).filter({ visible: true }).first()).toBeVisible({
    timeout: 20_000,
  });
  const doneMarker = `${marker}_DONE`;
  await sendPrompt(
    page,
    `Count from 1 to 400 in words, one number per line, without using any tools. After the last line, reply with exactly ${doneMarker}.`,
  );
  const stop = page.getByRole('button', { name: 'Stop response', exact: true }).filter({ visible: true });
  await expect(stop).toBeVisible({ timeout: 60_000 });
  await page.waitForTimeout(2_000);
  await stop.click();
  await expect(page.getByText('idle', { exact: true }).filter({ visible: true }).first()).toBeVisible({
    timeout: 60_000,
  });
  await expect(page.getByText('Stopped', { exact: true }).filter({ visible: true }).first()).toBeVisible({
    timeout: 30_000,
  });
  expect(await occurrences(page, doneMarker), 'the interrupted reply never reached its closing marker').toBe(1);
  await expect(page.locator('textarea').filter({ visible: true })).toBeEnabled({ timeout: 30_000 });
});
