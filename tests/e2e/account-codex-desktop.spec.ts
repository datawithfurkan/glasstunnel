import { readdirSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { expect, type Page, test } from '@playwright/test';

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for the local Codex desktop account test.`);
  return value;
}

/** Name of the dedicated Codex thread the lane may type into. */
const threadName = process.env.GT_LAB_CODEX_THREAD ?? 'Glasstunnel live evidence';
const codexHome = process.env.CODEX_HOME ?? path.join(homedir(), '.codex');

/** Newest rollout file whose text contains `needle`, or null. Reads only local Codex state. */
function newestRolloutContaining(needle: string): string | null {
  const root = path.join(codexHome, 'sessions');
  const files: { file: string; mtime: number }[] = [];
  const walk = (dir: string, depth: number) => {
    let entries: string[] = [];
    try {
      entries = readdirSync(dir);
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry);
      let info;
      try {
        info = statSync(full);
      } catch {
        continue;
      }
      if (info.isDirectory() && depth < 4) walk(full, depth + 1);
      else if (entry.startsWith('rollout-') && entry.endsWith('.jsonl')) files.push({ file: full, mtime: info.mtimeMs });
    }
  };
  walk(root, 0);
  files.sort((a, b) => b.mtime - a.mtime);
  for (const { file } of files.slice(0, 40)) {
    if (readFileSync(file, 'utf8').includes(needle)) return file;
  }
  return null;
}

/** Model and effort the thread runs, from its newest turn_context or settings record. */
function threadRuntime(file: string): { model: string; effort: string | null } | null {
  let model: string | undefined;
  let effort: string | null = null;
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    if (!line.includes('"turn_context"') && !line.includes('thread_settings_applied')) continue;
    let record: { type?: string; payload?: Record<string, unknown> };
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }
    const payload = record.payload ?? {};
    if (record.type === 'turn_context' && typeof payload.model === 'string') {
      model = payload.model;
      effort = typeof payload.effort === 'string' ? payload.effort : null;
    } else if (record.type === 'event_msg' && payload.type === 'thread_settings_applied') {
      const settings = (payload.thread_settings ?? {}) as Record<string, unknown>;
      if (typeof settings.model === 'string') {
        model = settings.model;
        effort = typeof settings.reasoning_effort === 'string' ? settings.reasoning_effort : null;
      }
    }
  }
  return model ? { model, effort } : null;
}

function modelDisplayName(slug: string): string {
  try {
    const catalog = JSON.parse(readFileSync(path.join(codexHome, 'models_cache.json'), 'utf8')) as {
      models?: { slug: string; display_name?: string }[];
    };
    return catalog.models?.find((model) => model.slug === slug)?.display_name ?? slug;
  } catch {
    return slug;
  }
}

const effortLabels: Record<string, string> = { xhigh: 'Extra high', high: 'High', medium: 'Medium', low: 'Low' };

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
  const back = page.getByRole('button', { name: 'Back to projects' }).filter({ visible: true });
  if (await back.isVisible().catch(() => false)) await back.click();
  const tab = page.getByRole('button', { name: label, exact: true }).filter({ visible: true });
  await expect(tab).toBeVisible({ timeout: 30_000 });
  await tab.click();
}

async function startIfOffered(page: Page): Promise<void> {
  const start = page.getByRole('button', { name: 'Start', exact: true }).filter({ visible: true });
  if (await start.isVisible().catch(() => false)) await start.click();
}

async function mainText(page: Page): Promise<string> {
  return page.locator('main').filter({ visible: true }).first().innerText();
}

async function occurrences(page: Page, text: string): Promise<number> {
  return (await mainText(page)).split(text).length - 1;
}

/** A finished turn: the reply text is in the transcript and the pill reads "done". */
async function turnFinished(page: Page, text: string, atLeast: number): Promise<void> {
  await expect.poll(() => occurrences(page, text), { timeout: 180_000 }).toBeGreaterThanOrEqual(atLeast);
  await expect(page.getByText('done', { exact: true }).filter({ visible: true }).first()).toBeVisible({
    timeout: 60_000,
  });
}

async function sendPrompt(page: Page, prompt: string): Promise<void> {
  const composer = page.locator('textarea').filter({ visible: true });
  await expect(composer).toBeEnabled({ timeout: 60_000 });
  await composer.fill(prompt);
  await page.getByRole('button', { name: /^Send( prompt)?$/ }).filter({ visible: true }).click();
}

/**
 * Drives the Codex desktop card from a phone-sized browser through the local
 * lab against the real Codex app (the ChatGPT-hosted shell): switches to a
 * dedicated thread, checks that the model chip shows what that thread really
 * runs, sends a prompt that the Mac types into the app's composer through
 * Accessibility, reads a shell command back as a titled row and fetches its
 * full output from the Mac, interrupts a long reply from the phone, and checks
 * that Codex's injected context never renders as the user's own words. Costs
 * three short turns on the signed-in Codex account.
 */
test('@codex-desktop-account shows the thread model, prompts, reads tool rows, and interrupts', async ({
  page,
}) => {
  test.setTimeout(600_000);
  // Hyphens rather than underscores: the app's composer stores typed text as
  // Markdown and would escape underscores.
  const marker = `GT-CODEX-APP-${Date.now()}`;

  await signInAndLinkHost(page);
  await openTab(page, 'Codex');
  await startIfOffered(page);

  // The dedicated thread is the only one the lane types into.
  const current = page
    .getByRole('button', { name: `Current session: ${threadName}`, exact: true })
    .filter({ visible: true });
  if (!(await current.isVisible().catch(() => false))) {
    const target = page
      .getByRole('button', { name: `Switch to ${threadName}`, exact: true })
      .filter({ visible: true });
    await expect(
      target,
      `Codex must have a thread named "${threadName}" (set GT_LAB_CODEX_THREAD to use another name)`,
    ).toBeVisible({ timeout: 90_000 });
    await target.click();
  }
  await expect(current).toBeVisible({ timeout: 30_000 });

  // 1. Plain prompt: typed into the real composer, answered, task_complete → "done".
  await sendPrompt(page, `Reply with exactly ${marker} and nothing else.`);
  await turnFinished(page, marker, 2);

  // The reply landed in the dedicated thread's own rollout, which proves the
  // Mac typed into that thread and not another one.
  const rollout = newestRolloutContaining(marker);
  expect(rollout, 'the prompt reached the dedicated thread on disk').not.toBeNull();

  // 2. The model chip reads the thread, not the global config. The thread's
  //    newest turn names the model it ran with; the card must show that.
  const runtime = threadRuntime(rollout!);
  expect(runtime, 'the thread records the model it runs').not.toBeNull();
  const runtimeBar = page.locator('section', { hasText: 'Managed in Codex' }).filter({ visible: true }).first();
  await expect(runtimeBar).toBeVisible({ timeout: 30_000 });
  await expect(runtimeBar).toContainText(modelDisplayName(runtime!.model), { timeout: 30_000 });
  if (runtime!.effort && effortLabels[runtime!.effort]) {
    await expect(runtimeBar).toContainText(effortLabels[runtime!.effort]);
  }
  test.info().annotations.push({
    type: 'model chip',
    description: `thread runs ${runtime!.model}${runtime!.effort ? ` / ${runtime!.effort}` : ''}; the card shows ${await runtimeBar.innerText()}`,
  });

  // 3. A shell command becomes a titled row; its full output is fetched from
  //    the Mac on request ("Show all N lines" after opening the row).
  const seqMarker = `${marker}-SEQ`;
  await sendPrompt(
    page,
    `Run this shell command, then reply with only its last line: seq 1 40 && echo ${seqMarker}`,
  );
  await turnFinished(page, seqMarker, 2);
  const seqRow = page.locator('.gt-tool-row', { hasText: 'seq 1 40' }).filter({ visible: true }).last();
  await expect(seqRow, 'the command is the row title').toBeVisible({ timeout: 30_000 });
  const showAll = seqRow.getByRole('button', { name: /^Show all \d+ lines$/ });
  if (!(await showAll.isVisible().catch(() => false))) await seqRow.locator('summary').click();
  await expect(showAll).toBeVisible({ timeout: 10_000 });
  const lineCount = Number((await showAll.innerText()).replace(/\D/g, ''));
  expect(lineCount, 'the Mac reports the full line count with the preview').toBeGreaterThanOrEqual(40);
  await showAll.click();
  await expect(seqRow.locator('.gt-tool-output')).toContainText(/(^|\n)40(\n|$)/, { timeout: 30_000 });
  await expect(showAll).toBeHidden();

  // 4. Interrupt from the phone: the Mac presses the app's Stop control (or
  //    sends Escape); the rollout records turn_aborted, so the card reads
  //    "idle" and the reply's closing marker never lands.
  const doneMarker = `${marker}-DONE`;
  await sendPrompt(
    page,
    `Count from 1 to 400 in words, one number per line, without using any tools. After the last line, reply with exactly ${doneMarker}.`,
  );
  const stop = page.getByRole('button', { name: 'Stop response', exact: true }).filter({ visible: true });
  await expect(stop).toBeVisible({ timeout: 60_000 });
  await page.waitForTimeout(4_000);
  await stop.click();
  await expect(page.getByText('idle', { exact: true }).filter({ visible: true }).first()).toBeVisible({
    timeout: 90_000,
  });
  await expect(stop).toBeHidden();
  expect(await occurrences(page, doneMarker), 'the interrupted reply never reached its closing marker').toBe(1);
  // The divider carries the time: "Stopped · 12:41".
  await expect(page.getByText(/^Stopped(\s*·\s*\d{1,2}:\d{2})?$/).filter({ visible: true }).last()).toBeVisible();

  // 5. Codex's machine-written context never renders as the user's words.
  const text = await mainText(page);
  expect(text).not.toContain('<environment_context');
  expect(text).not.toContain('<recommended_plugins');
});
