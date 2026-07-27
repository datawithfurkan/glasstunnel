import { expect, type Locator, test } from '@playwright/test';

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for the local Codex CLI account test.`);
  return value;
}

async function waitForRuntimeRestart(control: Locator) {
  await expect(control).toBeDisabled({ timeout: 10_000 });
  await expect(control).toBeEnabled({ timeout: 60_000 });
}

test('@codex-cli-account applies settings, starts, and interrupts Codex CLI through the local relay', async ({
  page,
}) => {
  test.setTimeout(180_000);

  const email = requiredEnv('GT_LAB_EMAIL');
  const password = requiredEnv('GT_LAB_PASSWORD');
  const linkCode = requiredEnv('GT_LAB_LINK_CODE');
  const hostLabel = requiredEnv('GT_LAB_HOST_LABEL');
  const markerSuffix = String(Date.now());

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

  const cliTab = page.getByRole('button', { name: 'CLI', exact: true }).filter({ visible: true });
  await expect(cliTab).toBeVisible({ timeout: 30_000 });
  await cliTab.click();

  const startButton = page
    .getByRole('button', { name: 'Start', exact: true })
    .filter({ visible: true });
  if (await startButton.isVisible().catch(() => false)) await startButton.click();

  const model = page.locator('select[aria-label="Model"]').filter({ visible: true });
  const effort = page.locator('select[aria-label="Effort"]').filter({ visible: true });
  const fast = page.getByRole('button', { name: 'Fast', exact: true }).filter({ visible: true });
  await expect(model).toBeVisible({ timeout: 60_000 });
  await expect(effort).toBeVisible();

  if ((await fast.count()) > 0 && (await fast.getAttribute('aria-pressed')) === 'true') {
    await fast.click();
  }

  const modelOptions = await model
    .locator('option')
    .evaluateAll((options) => options.map((option) => (option as HTMLOptionElement).value));
  const cheapestModel = ['gpt-5.4-mini', 'gpt-5.3-codex-spark'].find((candidate) =>
    modelOptions.includes(candidate),
  );
  if (!cheapestModel)
    throw new Error('No bounded-cost Codex model is available for the local test.');
  await model.selectOption(cheapestModel);
  await waitForRuntimeRestart(model);
  await expect(model).toHaveValue(cheapestModel);

  const effortOptions = await effort
    .locator('option')
    .evaluateAll((options) => options.map((option) => (option as HTMLOptionElement).value));
  if (effortOptions.includes('low')) {
    await effort.selectOption('low');
    await waitForRuntimeRestart(effort);
    await expect(effort).toHaveValue('low');
  }

  const composer = page.locator('textarea').filter({ visible: true });
  await expect(composer).toBeEnabled({ timeout: 60_000 });
  await composer.fill(
    `Analyze the marker GT_CODEX_LOCAL_${markerSuffix}, then wait before replying.`,
  );
  await page.getByRole('button', { name: 'Send prompt' }).filter({ visible: true }).click();
  const stop = page.getByRole('button', { name: 'Stop response' }).filter({ visible: true });
  await expect(stop).toBeVisible({ timeout: 20_000 });
  await expect
    .poll(
      async () => {
        const transcript = await page
          .locator('main pre')
          .filter({ visible: true })
          .allTextContents();
        return transcript.join('\n').includes(`GT_CODEX_LOCAL_${markerSuffix}`);
      },
      { timeout: 20_000 },
    )
    .toBe(true);
  await stop.click();

  await expect(composer).toBeEnabled({ timeout: 30_000 });
  await expect(stop).toBeHidden({ timeout: 30_000 });
  await expect(model).toBeEnabled();
});
