import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { expect, type Page, test } from '@playwright/test';

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for the local Claude desktop account test.`);
  return value;
}

/** Title of the dedicated Claude app session the lane may type into. */
const sessionTitle = process.env.GT_LAB_CLAUDE_SESSION ?? 'Glasstunnel live evidence';

/**
 * Mac-side helper that reads or switches the front session's permission mode
 * through Accessibility. It refuses to act unless the app shows `sessionTitle`,
 * so a run can never change the mode of one of the user's own sessions.
 */
const permissionModeHelper = path.resolve(process.cwd(), 'scripts/lab/claude-desktop-permission-mode.swift');

function permissionMode(...args: string[]): { ok: boolean; output: string } {
  try {
    const output = execFileSync('swift', [permissionModeHelper, '--session', sessionTitle, ...args], {
      encoding: 'utf8',
      timeout: 120_000,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return { ok: true, output: output.trim() };
  } catch (error) {
    const failed = error as { stdout?: string; stderr?: string };
    return { ok: false, output: `${failed.stdout ?? ''}${failed.stderr ?? ''}`.trim() || String(error) };
  }
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
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
 * a permission prompt (with the session switched to the app's ask-first mode
 * for that step) and an AskUserQuestion from the phone, interrupts a running
 * turn from the phone, and checks that the Claude Code CLI card started
 * alongside never inherits the desktop session's hook events. Costs four
 * short turns on the signed-in account.
 */
test('@claude-desktop-account prompts, answers permission and question dialogs, interrupts, and leaves the CLI card untouched', async ({
  page,
}) => {
  test.setTimeout(600_000);
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

  // The app's per-session permission mode decides whether a shell command
  // shows a dialog. Read it first so the run can put it back afterwards.
  const initialMode = permissionMode('--read');
  const initialModeName = initialMode.output.match(/^mode: (.+?)(?: \(|$)/)?.[1];
  test.info().annotations.push({ type: 'permission mode', description: initialMode.output });

  // 1. Plain prompt: typed into the real composer, answered, Stop hook → "Response ready".
  await sendPrompt(page, `Reply with exactly ${marker} and nothing else.`);
  await turnFinished(page, marker, 2);

  // 2. A file write behind the permission dialog. The session is switched to
  //    the app's "Manual" mode ("Always ask before making changes") for this
  //    step, so the Write reaches the phone as a decision and is answered
  //    Allow there; the mode is put back afterwards, even if the step fails.
  //    (A read-only shell command such as echo runs without a dialog even in
  //    Manual mode.) When the mode cannot be switched, the step records
  //    whether the session approved the write itself.
  const askMode = permissionMode('--set', '^Manual');
  test.info().annotations.push({ type: 'permission mode for the file write', description: askMode.output });
  const permissionMarker = `${marker}_PERM`;
  try {
    await sendPrompt(
      page,
      `Use your Write tool to create the file .cache/glasstunnel-lab/permission-${marker}.txt in the current working directory containing exactly ${permissionMarker}, then reply with only that file's contents.`,
    );
    const permissionCard = page
      .getByText('Claude needs a decision', { exact: true })
      .filter({ visible: true });
    const prompted = await permissionCard
      .waitFor({ state: 'visible', timeout: askMode.ok ? 90_000 : 25_000 })
      .then(() => true)
      .catch(() => false);
    if (prompted) await decide(page, /Allow/);
    if (askMode.ok) expect(prompted, 'the permission dialog reached the phone').toBe(true);
    test.info().annotations.push({
      type: 'permission dialog',
      description: prompted
        ? 'shown by the app and answered Allow from the phone'
        : 'not shown: the session permission mode approved the write itself',
    });
    await turnFinished(page, permissionMarker, 2);
  } finally {
    if (askMode.ok && initialModeName && !askMode.output.includes('(unchanged)')) {
      const restored = permissionMode('--set', `^${escapeRegExp(initialModeName)}$`);
      test.info().annotations.push({ type: 'permission mode restored', description: restored.output });
    }
  }

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

  // 4. Interrupt from the phone. A long reply is stopped through the app's
  //    own Stop control; the transcript then records the turn as stopped, so
  //    the card reads "idle" and the reply's closing marker never lands. (A
  //    long shell command is not a reliable target: Claude Code may run it in
  //    the background and finish the turn at once.)
  const doneMarker = `${marker}_DONE`;
  await sendPrompt(
    page,
    `Count from 1 to 400 in words, one number per line, without using any tools. After the last line, reply with exactly ${doneMarker}.`,
  );
  const stop = page.getByRole('button', { name: 'Stop response', exact: true }).filter({ visible: true });
  await expect(stop).toBeVisible({ timeout: 60_000 });
  await page.waitForTimeout(3_000);
  await stop.click();
  await expect(page.getByText('idle', { exact: true }).filter({ visible: true }).first()).toBeVisible({
    timeout: 90_000,
  });
  await expect(stop).toBeHidden();
  expect(await occurrences(page, doneMarker), 'the interrupted reply never reached its closing marker').toBe(1);

  // 5. The CLI card owns a different session, so none of the above moved it.
  await openTab(page, 'Code');
  await expect(page.getByText('Response ready', { exact: true })).toBeHidden();
  await expect(page.getByText('Claude needs a decision', { exact: true })).toBeHidden();
});
