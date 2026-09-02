import { expect, type Page, test } from '@playwright/test';

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for the local Claude Code account test.`);
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

async function transcriptIncludes(page: Page, marker: string): Promise<boolean> {
  const transcript = await page.locator('main pre').filter({ visible: true }).allTextContents();
  return transcript.join('\n').includes(marker);
}

/**
 * Drives the Claude Code CLI card from a phone-sized browser through the
 * local lab: the Mac launches the real `claude` binary in a PTY, a prompt is
 * answered end to end (Stop hook → "Response ready"), a second prompt is
 * interrupted from the phone, and the card recovers for the next prompt.
 * Costs two short turns on the signed-in Claude account.
 */
test('@claude-code-account prompts, receives a response, and interrupts Claude Code through the local relay', async ({
  page,
}) => {
  test.setTimeout(240_000);
  const marker = `GT_CLAUDE_CLI_${Date.now()}`;

  await signInAndLinkHost(page);

  const codeTab = page.getByRole('button', { name: 'Code', exact: true }).filter({ visible: true });
  await expect(codeTab).toBeVisible({ timeout: 30_000 });
  await codeTab.click();

  const startButton = page.getByRole('button', { name: 'Start', exact: true }).filter({ visible: true });
  if (await startButton.isVisible().catch(() => false)) await startButton.click();

  const composer = page.locator('textarea').filter({ visible: true });
  await expect(composer).toBeEnabled({ timeout: 90_000 });
  // The card publishes the CLI's sessions once the PTY is up and the store
  // has been read; the selected one is the session Claude Code resumed.
  await expect(
    page.getByRole('button', { name: /^Current session: / }).filter({ visible: true }),
  ).toBeVisible({ timeout: 60_000 });

  // A folder Claude Code has not seen from this launch opens with its
  // workspace-trust dialog a few seconds after the process starts; the card
  // turns it into a decision for the phone. Wait for a ready state that has
  // held for a while with no decision pending before typing anything.
  const ready = page.getByText('ready', { exact: true }).filter({ visible: true });
  const trustDecision = page
    .getByText('Claude Code needs a decision', { exact: true })
    .filter({ visible: true });
  const deadline = Date.now() + 150_000;
  let settledReadySince: number | null = null;
  while (Date.now() < deadline) {
    if (await trustDecision.isVisible().catch(() => false)) {
      await page
        .getByRole('button', { name: /Yes, I trust this folder/ })
        .filter({ visible: true })
        .first()
        .click();
      await page.getByRole('button', { name: 'Continue', exact: true }).filter({ visible: true }).click();
      await expect(trustDecision).toBeHidden({ timeout: 30_000 });
      settledReadySince = null;
    } else if (await ready.isVisible().catch(() => false)) {
      settledReadySince ??= Date.now();
      if (Date.now() - settledReadySince >= 8_000) break;
    } else {
      settledReadySince = null;
    }
    await page.waitForTimeout(1_000);
  }
  await expect(ready).toBeVisible();
  await expect(trustDecision).toBeHidden();

  await composer.fill(`Reply with exactly ${marker} and nothing else.`);
  const send = page.getByRole('button', { name: 'Send prompt' }).filter({ visible: true });
  await send.click();

  // The Stop hook publishes "Response ready" (shown in the card header and the
  // terminal frame); the transcript carries the marker both as the echoed
  // prompt and as the assistant's reply.
  await expect(
    page.getByText('Response ready', { exact: true }).filter({ visible: true }).first(),
  ).toBeVisible({ timeout: 120_000 });
  await expect.poll(async () => transcriptIncludes(page, marker), { timeout: 20_000 }).toBe(true);

  await composer.fill(
    `Count slowly from one to two hundred, one number per line, then say ${marker}_DONE.`,
  );
  await send.click();
  const stop = page.getByRole('button', { name: 'Stop response' }).filter({ visible: true });
  await expect(stop).toBeVisible({ timeout: 30_000 });
  await stop.click();

  await expect(stop).toBeHidden({ timeout: 30_000 });
  await expect(composer).toBeEnabled({ timeout: 30_000 });
  await expect(send).toBeVisible();
});
