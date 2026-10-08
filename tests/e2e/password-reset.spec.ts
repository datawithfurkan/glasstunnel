import { randomBytes } from 'node:crypto';

import { expect, test, type Locator, type Page, type Route } from '@playwright/test';

// Password reset by email against the local lab backend. The backend runs with
// AUTH_EMAIL_OUTBOX=lab, so nothing is sent: emails land in the local
// labEmailOutbox table and this spec reads them through the lab's admin CLI.
// scripts/lab/e2e.mjs creates GT_LAB_RESET_EMAIL (password GT_LAB_PASSWORD)
// before Playwright starts and deletes it afterwards. The @password-reset-mac
// case also needs the Swift host's GT_LAB_LINK_CODE and GT_LAB_HOST_LABEL, so
// it runs in its own lab (node scripts/lab/e2e.mjs password-reset-mac).
//
// Never log passwords, reset links, tokens, or link codes. Assertions below
// compare derived booleans and lengths so a failure cannot print a live token.

type LabEmail = {
  kind: 'password_reset' | 'password_changed';
  to: string;
  subject: string;
  text: string;
  url: string | null;
  createdAt: number;
};

type LabConfigModule = typeof import('../../scripts/lab/config.mjs');
type LabConvexModule = typeof import('../../scripts/lab/convex.mjs');
type LabSettings = ReturnType<LabConfigModule['labConfig']>;

let labModules: Promise<[LabConfigModule, LabConvexModule]> | undefined;

/**
 * The lab scripts (scripts/lab/config.mjs and convex.mjs) are ES modules that
 * use import.meta. Playwright compiles this spec to CommonJS, where a static
 * import of them fails, so they load at run time with a native import().
 */
function lab(): Promise<[LabConfigModule, LabConvexModule]> {
  return (labModules ??= Promise.all([
    import('../../scripts/lab/config.mjs'),
    import('../../scripts/lab/convex.mjs'),
  ]));
}

async function readLabEmails(config: LabSettings, to: string): Promise<LabEmail[]> {
  const [, convex] = await lab();
  return (await convex.readLabEmails(config, to)) as LabEmail[];
}

const RESET_TOKEN_STORAGE_KEY = 'gt.password-reset-token';
const NEUTRAL_CONFIRMATION =
  'If an account exists for that email, we sent a link to reset your password. It expires in 1 hour.';
const RESET_UNAVAILABLE = "Password reset isn't available yet. Sign in with Google or GitHub instead.";
const RESET_THROTTLED = 'Too many reset requests. Wait a minute and try again.';
const PASSWORD_UPDATED = 'Password updated. Sign in with your new password.';
const LINK_USED = 'This reset link has expired or was already used. Request a new one.';
const PASSWORDS_DIFFER = "The passwords don't match.";
const PASSWORD_TOO_SHORT = 'Use at least 8 characters.';

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for the local password reset test (run pnpm lab:e2e:password-reset).`);
  return value;
}

async function labSettings(): Promise<LabSettings> {
  const [config] = await lab();
  // GT_LAB_ROOT comes from scripts/lab/e2e.mjs; the default is this checkout.
  return config.labConfig(process.env.GT_LAB_ROOT || undefined);
}

function randomPassword(): string {
  return `Lab-Reset-${randomBytes(12).toString('base64url')}`;
}

function authPath(path: string) {
  return (url: URL) => url.pathname.endsWith(`/api/auth/${path}`);
}

async function openEmailSignIn(page: Page, email: string, startPath = '/?authProvider=email') {
  await page.goto(startPath);
  await expect(page.getByRole('heading', { name: 'Open your agents' })).toBeVisible();
  await page.getByPlaceholder('you@example.com').filter({ visible: true }).fill(email);
  await page.getByRole('button', { name: 'Continue with email', exact: true }).click();
  await expect(page.getByPlaceholder('Enter your password')).toBeVisible();
}

async function signInWithPassword(page: Page, password: string) {
  await page.getByPlaceholder('Enter your password').fill(password);
  await page.getByRole('button', { name: 'Sign in', exact: true }).last().click();
}

function forgotPasswordButton(page: Page): Locator {
  return page.getByRole('button', { name: 'Forgot password?', exact: true });
}

function sendResetLinkButton(page: Page): Locator {
  return page.getByRole('button', { name: 'Send reset link', exact: true }).filter({ visible: true });
}

/** From the password step to the forgot screen, with the typed email carried over. */
async function openForgotPassword(page: Page, email: string) {
  await forgotPasswordButton(page).click();
  await expect(page.getByRole('heading', { name: 'Reset your password' })).toBeVisible();
  await expect(page.getByPlaceholder('you@example.com').filter({ visible: true })).toHaveValue(email);
}

/** Any of the sign-in entry points the app may return to after "Back to sign in". */
function signInEntry(page: Page): Locator {
  return page
    .getByPlaceholder('Enter your password')
    .or(page.getByRole('button', { name: 'Continue with email', exact: true }))
    .or(page.getByRole('button', { name: 'Continue with email instead', exact: true }))
    .filter({ visible: true })
    .first();
}

async function resetTokenStored(page: Page): Promise<boolean> {
  return page.evaluate((key) => window.sessionStorage.getItem(key) !== null, RESET_TOKEN_STORAGE_KEY);
}

async function tokenInAddressBar(page: Page): Promise<boolean> {
  return new URL(page.url()).searchParams.has('token');
}

/** Waits for an email of this kind created at or after `since` (server and lab share this machine's clock). */
async function waitForLabEmail(
  config: LabSettings,
  to: string,
  kind: LabEmail['kind'],
  since: number,
): Promise<LabEmail> {
  let found: LabEmail | undefined;
  await expect
    .poll(
      async () => {
        const emails = await readLabEmails(config, to);
        found = emails.find((entry) => entry.kind === kind && entry.createdAt >= since);
        return found !== undefined;
      },
      {
        message: `a new ${kind} email in the local lab outbox (a rerun within 2 minutes is throttled; reset the lab first)`,
        timeout: 15_000,
        intervals: [250, 500, 1_000],
      },
    )
    .toBe(true);
  return found!;
}

/** Whether a bearer session is still valid on the local auth server. */
async function sessionIsActive(config: LabSettings, token: string): Promise<boolean> {
  const response = await fetch(new URL('/api/auth/get-session', config.urls.convexSite), {
    headers: { authorization: `Bearer ${token}`, origin: config.urls.pwa },
  });
  if (response.status === 401) return false;
  if (!response.ok) throw new Error(`The local get-session check answered HTTP ${response.status}.`);
  const body = (await response.json().catch(() => null)) as { session?: unknown } | null;
  return Boolean(body?.session);
}

/** Holds one auth request until released so the busy state stays on screen. */
async function holdAuthRequest(page: Page, path: string) {
  let release!: () => void;
  const released = new Promise<void>((resolve) => {
    release = resolve;
  });
  const matcher = authPath(path);
  const handler = async (route: Route) => {
    await released;
    await route.continue();
  };
  await page.route(matcher, handler, { times: 1 });
  return {
    release,
    dispose: () => page.unroute(matcher, handler),
  };
}

function mockedAuthError(page: Page, status: number, body: Record<string, unknown>) {
  // The auth server is another origin, so the fake answer carries CORS headers
  // like the real one does (Playwright answers the preflight itself).
  const appOrigin = new URL(page.url()).origin;
  return {
    status,
    contentType: 'application/json',
    headers: {
      'access-control-allow-origin': appOrigin,
      'access-control-allow-credentials': 'true',
      vary: 'Origin',
    },
    body: JSON.stringify(body),
  };
}

test('@password-reset resets a forgotten password from the emailed link and signs in with the new one', async ({
  page,
}) => {
  test.setTimeout(120_000);
  const config = await labSettings();
  const email = requiredEnv('GT_LAB_RESET_EMAIL');
  const oldPassword = requiredEnv('GT_LAB_PASSWORD');
  const newPassword = process.env.GT_LAB_RESET_NEW_PASSWORD || randomPassword();
  expect(newPassword === oldPassword).toBe(false);

  // A session from another device before the reset; the server must end it.
  const [, convex] = await lab();
  const otherDevice = await convex.signInLabUser({ config, email, password: oldPassword });
  expect(await sessionIsActive(config, otherDevice.token)).toBe(true);

  // Forgot password -> the same neutral confirmation for every address.
  await openEmailSignIn(page, email);
  await openForgotPassword(page, email);
  const requestedAt = Date.now() - 2_000;
  await sendResetLinkButton(page).click();
  await expect(page.getByText(NEUTRAL_CONFIRMATION)).toBeVisible();
  await page.getByRole('button', { name: 'Back to sign in', exact: true }).click();
  await expect(page.getByText(NEUTRAL_CONFIRMATION)).toBeHidden();
  await expect(signInEntry(page)).toBeVisible();

  // The reset email reaches the lab outbox once and links straight to the app.
  const resetEmail = await waitForLabEmail(config, email, 'password_reset', requestedAt);
  expect(resetEmail.to).toBe(email);
  expect(resetEmail.subject.length).toBeGreaterThan(0);
  const link = new URL(resetEmail.url ?? 'about:blank');
  expect(link.origin).toBe(new URL(page.url()).origin);
  expect(link.pathname).toBe('/');
  expect(link.searchParams.get('resetPassword')).toBe('1');
  expect((link.searchParams.get('token') ?? '').length).toBeGreaterThan(0);
  const resetEmails = (await readLabEmails(config, email)).filter(
    (entry) => entry.kind === 'password_reset' && entry.createdAt >= requestedAt,
  );
  expect(resetEmails.length).toBe(1);

  // This browser is still signed in (old password) when the link is opened.
  await openEmailSignIn(page, email);
  await signInWithPassword(page, oldPassword);
  const lastSignInAt = Date.now();
  const macsHeading = page.getByRole('heading', { name: 'Your Macs', exact: true });
  await expect(macsHeading).toBeVisible({ timeout: 20_000 });

  // Opening the link: the token leaves the address bar and lives in this tab only.
  await page.goto(link.href);
  const chooseHeading = page.getByRole('heading', { name: 'Choose a new password' });
  await expect(chooseHeading).toBeVisible();
  await expect.poll(() => tokenInAddressBar(page)).toBe(false);
  expect(await resetTokenStored(page)).toBe(true);
  await page.reload();
  await expect(chooseHeading).toBeVisible();
  expect(await tokenInAddressBar(page)).toBe(false);

  const newPasswordInput = page.getByLabel('New password', { exact: true });
  const confirmPasswordInput = page.getByLabel('Confirm new password', { exact: true });
  const updateButton = page.getByRole('button', { name: 'Update password', exact: true });

  // Checks that run before the one-time token is spent.
  await newPasswordInput.fill('short1');
  await confirmPasswordInput.fill('short1');
  if (await updateButton.isEnabled()) await updateButton.click();
  await expect(page.getByText(PASSWORD_TOO_SHORT)).toBeVisible();
  await newPasswordInput.fill(newPassword);
  await confirmPasswordInput.fill(`${newPassword}-x`);
  if (await updateButton.isEnabled()) await updateButton.click();
  await expect(page.getByText(PASSWORDS_DIFFER)).toBeVisible();

  // Update, with the busy state visible while the server works.
  await confirmPasswordInput.fill(newPassword);
  const heldReset = await holdAuthRequest(page, 'reset-password');
  await updateButton.click();
  const updatingButton = page.getByRole('button', { name: 'Updating…', exact: true });
  await expect(updatingButton).toBeVisible();
  await expect(updatingButton).toBeDisabled();
  heldReset.release();
  await expect(page.getByText(PASSWORD_UPDATED)).toBeVisible();
  await heldReset.dispose();
  expect(await resetTokenStored(page)).toBe(false);
  expect(await tokenInAddressBar(page)).toBe(false);

  // The server ended every session and queued a "password changed" notice without a link.
  expect(await sessionIsActive(config, otherDevice.token)).toBe(false);
  const changedEmail = await waitForLabEmail(config, email, 'password_changed', requestedAt);
  expect(changedEmail.to).toBe(email);
  expect(changedEmail.url === null).toBe(true);

  // This browser dropped its own session too: back to sign-in, not to the Macs list.
  await page.getByRole('button', { name: 'Back to sign in', exact: true }).click();
  await expect(chooseHeading).toBeHidden();
  await expect(signInEntry(page)).toBeVisible();
  await expect(macsHeading).toHaveCount(0);
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Open your agents' })).toBeVisible({ timeout: 20_000 });
  await expect(macsHeading).toHaveCount(0);

  // The same link works only once.
  await page.goto(link.href);
  await expect(chooseHeading).toBeVisible();
  const unusedPassword = randomPassword();
  await newPasswordInput.fill(unusedPassword);
  await confirmPasswordInput.fill(unusedPassword);
  await updateButton.click();
  await expect(page.getByText(LINK_USED)).toBeVisible();
  expect(await resetTokenStored(page)).toBe(false);
  await page.getByRole('button', { name: 'Request a new link', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Reset your password' })).toBeVisible();
  await expect(sendResetLinkButton(page)).toBeVisible();

  // When Better Auth rate limits, it allows 3 sign-in attempts until 10 quiet
  // seconds pass. Two ran above; let the window close before two more.
  const quietLeft = lastSignInAt + 10_500 - Date.now();
  if (quietLeft > 0) await page.waitForTimeout(quietLeft);

  // The old password is rejected; the new one reaches the account's (empty) Macs list.
  await openEmailSignIn(page, email);
  await signInWithPassword(page, oldPassword);
  await expect(page.getByRole('alert').filter({ hasText: 'Wrong email or password' })).toBeVisible();
  await signInWithPassword(page, newPassword);
  await expect(macsHeading).toBeVisible({ timeout: 20_000 });
  await expect(page.getByText('Enter the code shown on your Mac.', { exact: true })).toBeVisible();
});

test('@password-reset answers an unknown email exactly like a known one and sends nothing', async ({ page }) => {
  test.setTimeout(60_000);
  const config = await labSettings();
  const unknownEmail = 'no-account-reset@glasstunnel.test';

  await openEmailSignIn(page, unknownEmail);
  await openForgotPassword(page, unknownEmail);
  await sendResetLinkButton(page).click();
  await expect(page.getByText(NEUTRAL_CONFIRMATION)).toBeVisible();
  expect((await readLabEmails(config, unknownEmail)).length).toBe(0);

  await page.getByRole('button', { name: 'Back to sign in', exact: true }).click();
  await expect(page.getByText(NEUTRAL_CONFIRMATION)).toBeHidden();
  await expect(signInEntry(page)).toBeVisible();
});

test('@password-reset forgot password shows its sign-in-only entry, busy, unavailable and throttled states', async ({
  page,
}) => {
  // Error answers are mocked in the browser; no request reaches the backend.
  const email = 'mocked-reset@glasstunnel.test';
  const requestBodies: unknown[] = [];

  await openEmailSignIn(page, email);
  const forgot = forgotPasswordButton(page);
  await expect(forgot).toBeVisible();
  await page.getByRole('button', { name: 'Create account', exact: true }).first().click();
  await expect(forgot).toBeHidden();
  await page.getByRole('button', { name: 'Sign in', exact: true }).first().click();
  await expect(forgot).toBeVisible();

  // Reset email delivery not configured: Better Auth answers RESET_PASSWORD_DISABLED.
  await openForgotPassword(page, email);
  let releaseDisabled!: () => void;
  const disabledReleased = new Promise<void>((resolve) => {
    releaseDisabled = resolve;
  });
  await page.route(
    authPath('request-password-reset'),
    async (route) => {
      requestBodies.push(route.request().postDataJSON());
      await disabledReleased;
      await route.fulfill(
        mockedAuthError(page, 400, {
          code: 'RESET_PASSWORD_DISABLED',
          message: "Reset password isn't enabled",
        }),
      );
    },
    { times: 1 },
  );
  await sendResetLinkButton(page).click();
  const sendingButton = page.getByRole('button', { name: 'Sending…', exact: true });
  await expect(sendingButton).toBeVisible();
  await expect(sendingButton).toBeDisabled();
  releaseDisabled();
  await expect(page.getByText(RESET_UNAVAILABLE)).toBeVisible();
  await expect(page.getByText(NEUTRAL_CONFIRMATION)).toHaveCount(0);

  // Rate limited by the auth server.
  await page.route(
    authPath('request-password-reset'),
    async (route) => {
      requestBodies.push(route.request().postDataJSON());
      await route.fulfill(
        mockedAuthError(page, 429, { message: 'Too many requests. Please try again later.' }),
      );
    },
    { times: 1 },
  );
  await openEmailSignIn(page, email);
  await openForgotPassword(page, email);
  await sendResetLinkButton(page).click();
  await expect(page.getByText(RESET_THROTTLED)).toBeVisible();
  await expect(page.getByText(NEUTRAL_CONFIRMATION)).toHaveCount(0);

  // The app sends only the email: no redirect URL for the server to trust.
  expect(requestBodies).toEqual([{ email }, { email }]);
});

function isHostCodeClaim(request: { url(): string; method(): string }): boolean {
  return request.url().includes('/account/claim-host-code') && request.method() === 'POST';
}

/** Whether the tab's address bar carries a Mac linkCode; a boolean, so a failure never prints the code. */
async function addressBarHasLinkCode(page: Page): Promise<boolean> {
  return new URL(page.url()).searchParams.has('linkCode');
}

// Runs alone with the Swift host (node scripts/lab/e2e.mjs password-reset-mac):
// the reset account claims the host's one link code, which the account journey
// in the default lab claims for the lab user instead.
test('@password-reset-mac links the Mac that started sign-in after a reset from the emailed link in a new tab', async ({
  page,
  context,
}) => {
  test.setTimeout(120_000);
  const config = await labSettings();
  const email = requiredEnv('GT_LAB_RESET_EMAIL');
  const newPassword = process.env.GT_LAB_RESET_NEW_PASSWORD || randomPassword();
  const linkCode = requiredEnv('GT_LAB_LINK_CODE');
  const hostLabel = requiredEnv('GT_LAB_HOST_LABEL');
  expect(newPassword === requiredEnv('GT_LAB_PASSWORD')).toBe(false);

  // Claims of the Mac's code from every tab of this browser.
  let claimRequests = 0;
  context.on('request', (request) => {
    if (isHostCodeClaim(request)) claimRequests += 1;
  });

  // The Mac opens email sign-in with its link code; the person forgot the password.
  await openEmailSignIn(page, email, `/?authProvider=email&linkCode=${encodeURIComponent(linkCode)}`);
  await openForgotPassword(page, email);
  const requestedAt = Date.now() - 2_000;
  await sendResetLinkButton(page).click();
  await expect(page.getByText(NEUTRAL_CONFIRMATION)).toBeVisible();

  // The emailed link knows nothing about the Mac.
  const resetEmail = await waitForLabEmail(config, email, 'password_reset', requestedAt);
  const link = new URL(resetEmail.url ?? 'about:blank');
  expect(link.searchParams.has('linkCode')).toBe(false);
  expect(link.searchParams.get('resetPassword')).toBe('1');

  // The mail app opens it in a new tab of the same browser; the first tab stays open.
  const resetPage = await context.newPage();
  await resetPage.goto(link.href);
  await expect(resetPage.getByRole('heading', { name: 'Choose a new password' })).toBeVisible();
  await expect.poll(() => tokenInAddressBar(resetPage)).toBe(false);
  await resetPage.getByLabel('New password', { exact: true }).fill(newPassword);
  await resetPage.getByLabel('Confirm new password', { exact: true }).fill(newPassword);
  await resetPage.getByRole('button', { name: 'Update password', exact: true }).click();
  await expect(resetPage.getByText(PASSWORD_UPDATED)).toBeVisible();

  // "Back to sign in" only returns to sign-in. The Mac's code stays out of
  // every address bar until a sign-in to the account it was kept for, so a
  // later sign-in by someone else on this browser cannot claim it.
  await resetPage.getByRole('button', { name: 'Back to sign in', exact: true }).click();
  await expect(signInEntry(resetPage)).toBeVisible();
  expect(await addressBarHasLinkCode(resetPage)).toBe(false);
  expect(await addressBarHasLinkCode(page)).toBe(false);
  expect(claimRequests).toBe(0);

  // The sign-in form offers the address the reset was for. Signing in with the
  // new password links that Mac, as the Mac's own sign-in would have.
  await expect(resetPage.getByPlaceholder('you@example.com').filter({ visible: true })).toHaveValue(email);
  await resetPage.getByRole('button', { name: 'Continue with email', exact: true }).click();
  const claimResponse = resetPage.waitForResponse((response) => isHostCodeClaim(response.request()));
  await signInWithPassword(resetPage, newPassword);
  expect((await claimResponse).ok()).toBe(true);
  await expect(
    resetPage.getByText(hostLabel, { exact: true }).filter({ visible: true }).first(),
  ).toBeVisible({ timeout: 20_000 });
  expect(await addressBarHasLinkCode(resetPage)).toBe(false);

  // The first tab follows the sign-in but does not claim the code a second time,
  // so neither tab shows a "link code not found" error for a Mac that was linked.
  await expect(page.getByText(NEUTRAL_CONFIRMATION)).toBeHidden({ timeout: 20_000 });
  await expect(
    page
      .getByRole('heading', { name: 'Your Macs', exact: true })
      .or(page.getByText(hostLabel, { exact: true }))
      .filter({ visible: true })
      .first(),
  ).toBeVisible({ timeout: 20_000 });
  await page.waitForTimeout(1_500);
  expect(claimRequests).toBe(1);
  expect(await addressBarHasLinkCode(page)).toBe(false);
  for (const tab of [page, resetPage]) {
    await expect(tab.getByText(/link code (not found|expired)/i)).toHaveCount(0);
  }

  // Reloaded, the first tab is signed in to the same account and lists that Mac.
  await page.reload();
  await expect(page.getByText(hostLabel, { exact: true }).filter({ visible: true }).first()).toBeVisible({
    timeout: 20_000,
  });
  expect(claimRequests).toBe(1);
  await resetPage.close();
});
