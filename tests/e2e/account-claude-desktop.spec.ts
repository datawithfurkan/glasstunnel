import { expect, type Page, test } from '@playwright/test';

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
  // The app tabs live on the workspace list; an open card hides them behind
  // "Back to projects".
  const back = page.getByRole('button', { name: 'Back to projects' }).filter({ visible: true });
  if (await back.isVisible().catch(() => false)) await back.click();
  const tab = page.getByRole('button', { name: label, exact: true }).filter({ visible: true });
  await expect(tab).toBeVisible({ timeout: 30_000 });
  await tab.click();
}

/**
 * Waits until a CLI card has been steadily "ready" with no decision pending,
 * answering Claude Code's workspace-trust dialog on the way (it can appear a
 * few seconds after launch, and again after a held-session fallback).
 */
async function settleCliCard(page: Page): Promise<void> {
  const ready = page.getByText('ready', { exact: true }).filter({ visible: true });
  const decision = page
    .getByText('Claude Code needs a decision', { exact: true })
    .filter({ visible: true });
  const deadline = Date.now() + 150_000;
  let readySince: number | null = null;
  while (Date.now() < deadline) {
    if (await decision.isVisible().catch(() => false)) {
      await page
        .getByRole('button', { name: /Yes, I trust this folder/ })
        .filter({ visible: true })
        .first()
        .click();
      await page.getByRole('button', { name: 'Continue', exact: true }).filter({ visible: true }).click();
      await expect(decision).toBeHidden({ timeout: 30_000 });
      readySince = null;
    } else if (await ready.isVisible().catch(() => false)) {
      readySince ??= Date.now();
      if (Date.now() - readySince >= 8_000) break;
    } else {
      readySince = null;
    }
    await page.waitForTimeout(1_000);
  }
  await expect(ready).toBeVisible();
  await expect(decision).toBeHidden();
}

async function startIfOffered(page: Page): Promise<void> {
  const start = page.getByRole('button', { name: 'Start', exact: true }).filter({ visible: true });
  if (await start.isVisible().catch(() => false)) await start.click();
}

async function occurrences(page: Page, text: string): Promise<number> {
  const body = await page.locator('main').filter({ visible: true }).first().innerText();
  return body.split(text).length - 1;
}

/**
 * A chat-style card shows the project path under its title rather than the
 * status detail, so a finished turn is recognised by the reply text landing
 * in the transcript and the status pill reading "done".
 */
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
  // Chat-style cards label the button "Send"; CLI cards "Send prompt".
  await page.getByRole('button', { name: /^Send( prompt)?$/ }).filter({ visible: true }).click();
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
  await expect(
    page.getByRole('button', { name: /^Current session: / }).filter({ visible: true }),
  ).toBeVisible({ timeout: 60_000 });
  await settleCliCard(page);

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
  await turnFinished(page, marker, 2);

  // 2. A tool call that may need permission. Sessions in the app's "auto"
  //    permission mode approve a harmless shell command themselves, so the
  //    dialog is answered when it appears and its absence is recorded.
  const permissionMarker = `${marker}_PERM`;
  await sendPrompt(
    page,
    `Run this shell command with your Bash tool and show me its output: echo ${permissionMarker}`,
  );
  const permissionCard = page
    .getByText('Claude needs a decision', { exact: true })
    .filter({ visible: true });
  const prompted = await permissionCard
    .waitFor({ state: 'visible', timeout: 25_000 })
    .then(() => true)
    .catch(() => false);
  if (prompted) await decide(page, /Allow/);
  test.info().annotations.push({
    type: 'permission dialog',
    description: prompted
      ? 'shown by the app and answered Allow from the phone'
      : 'not shown: the session permission mode approved the command itself',
  });
  await turnFinished(page, permissionMarker, 2);

  // 3. AskUserQuestion answered from the phone. Sessions in "auto" permission
  //    mode first ask permission to use the tool (a second decision card), and
  //    the question itself follows once that is allowed.
  await sendPrompt(
    page,
    `Use your AskUserQuestion tool to ask me one question with exactly two options labelled Alpha and Beta. After I answer, reply with only the label I picked followed by _PICKED_${marker}.`,
  );
  let questionAnswered = false;
  let toolPermissionAnswered = false;
  const questionDeadline = Date.now() + 240_000;
  while (Date.now() < questionDeadline && (await occurrences(page, `Beta_PICKED_${marker}`)) < 1) {
    const card = page.getByText('Claude needs a decision', { exact: true }).filter({ visible: true });
    if (await card.isVisible().catch(() => false)) {
      const beta = page.getByRole('button', { name: /\bBeta\b/ }).filter({ visible: true }).first();
      const allow = page.getByRole('button', { name: /\bAllow\b/ }).filter({ visible: true }).first();
      if (await beta.isVisible().catch(() => false)) {
        await beta.click();
        questionAnswered = true;
      } else if (await allow.isVisible().catch(() => false)) {
        await allow.click();
        toolPermissionAnswered = true;
      } else {
        await page.waitForTimeout(1_000);
        continue;
      }
      await page.getByRole('button', { name: 'Continue', exact: true }).filter({ visible: true }).click();
      await card.waitFor({ state: 'hidden', timeout: 60_000 }).catch(() => undefined);
    }
    await page.waitForTimeout(1_000);
  }
  expect(questionAnswered, 'the question reached the phone and was answered there').toBe(true);
  test.info().annotations.push({
    type: 'AskUserQuestion',
    description: toolPermissionAnswered
      ? 'tool permission allowed from the phone, then the question answered from the phone'
      : 'question answered from the phone (no tool permission dialog)',
  });
  await turnFinished(page, `Beta_PICKED_${marker}`, 1);

  // 4. The CLI card owns a different session, so none of the above moved it.
  await openTab(page, 'Code');
  await expect(page.getByText('Response ready', { exact: true })).toBeHidden();
  await expect(page.getByText('Claude needs a decision', { exact: true })).toBeHidden();
});
