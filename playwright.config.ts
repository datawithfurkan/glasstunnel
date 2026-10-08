import { defineConfig, devices } from '@playwright/test';
import path from 'node:path';

const baseURL = process.env.GT_LAB_BASE_URL ?? 'http://127.0.0.1:5173';
const outputDir = path.join(process.cwd(), '.cache/glasstunnel-lab/playwright/results');

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 45_000,
  expect: { timeout: 10_000 },
  outputDir,
  reporter: [
    ['line'],
    [
      'html',
      {
        open: 'never',
        outputFolder: '.cache/glasstunnel-lab/playwright/report',
      },
    ],
  ],
  use: {
    baseURL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  projects: [
    {
      name: 'fixture-desktop-chromium',
      grep: /@fixture/,
      use: {
        ...devices['Desktop Chrome'],
        viewport: { width: 1440, height: 900 },
      },
    },
    {
      name: 'fixture-mobile-chromium',
      grep: /@fixture/,
      use: {
        ...devices['Pixel 7'],
      },
    },
    {
      name: 'local-account-chromium',
      grep: /@account/,
      use: {
        ...devices['Desktop Chrome'],
        viewport: { width: 1280, height: 800 },
      },
    },
    {
      name: 'local-revocation-mobile-chromium',
      grep: /@revocation-account/,
      use: { ...devices['Pixel 7'] },
    },
    {
      name: 'local-retention-mobile-chromium',
      grep: /@retention-account/,
      use: { ...devices['Pixel 7'] },
    },
    {
      name: 'local-account-mobile-chromium',
      grep: /@account/,
      use: {
        ...devices['Pixel 7'],
      },
    },
    {
      // Runs after the account journey in the default Chromium lab.
      // Forgot password -> lab email outbox -> new password -> sign in.
      // Needs the local backend only (no Mac host); see scripts/lab/e2e.mjs.
      name: 'local-password-reset-mobile-chromium',
      grep: /@password-reset/,
      grepInvert: /@password-reset-mac/,
      use: { ...devices['Pixel 7'] },
    },
    {
      // The same reset started from a Mac (?linkCode=): the next sign-in must
      // link that Mac. Needs the Swift host's fresh link code, so it runs alone:
      // node scripts/lab/e2e.mjs password-reset-mac.
      name: 'local-password-reset-mac-mobile-chromium',
      grep: /@password-reset-mac/,
      use: { ...devices['Pixel 7'] },
    },
    {
      name: 'local-codex-cli-mobile-chromium',
      grep: /@codex-cli-account/,
      use: {
        ...devices['Pixel 7'],
      },
    },
    {
      name: 'local-cursor-agent-mobile-chromium',
      grep: /@cursor-agent-account/,
      use: {
        ...devices['Pixel 7'],
      },
    },
    {
      name: 'local-cursor-agent-mobile-webkit',
      grep: /@cursor-agent-account/,
      use: {
        ...devices['iPhone 15'],
      },
    },
    {
      name: 'local-cursor-desktop-mobile-chromium',
      grep: /@cursor-desktop-account/,
      use: {
        ...devices['Pixel 7'],
      },
    },
    {
      name: 'local-cursor-desktop-mobile-webkit',
      grep: /@cursor-desktop-account/,
      use: {
        ...devices['iPhone 15'],
      },
    },
    {
      name: 'local-claude-code-mobile-chromium',
      grep: /@claude-code-account/,
      use: {
        ...devices['Pixel 7'],
      },
    },
    {
      name: 'local-claude-desktop-mobile-chromium',
      grep: /@claude-desktop-account/,
      use: {
        ...devices['Pixel 7'],
      },
    },
    {
      name: 'local-codex-desktop-mobile-chromium',
      grep: /@codex-desktop-account/,
      use: {
        ...devices['Pixel 7'],
      },
    },
    {
      name: 'local-claude-code-mobile-webkit',
      grep: /@claude-code-account/,
      use: {
        ...devices['iPhone 15'],
      },
    },
    {
      name: 'local-claude-desktop-mobile-webkit',
      grep: /@claude-desktop-account/,
      use: {
        ...devices['iPhone 15'],
      },
    },
    {
      name: 'local-codex-desktop-mobile-webkit',
      grep: /@codex-desktop-account/,
      use: {
        ...devices['iPhone 15'],
      },
    },
    {
      name: 'fixture-mobile-webkit',
      grep: /@fixture/,
      use: {
        ...devices['iPhone 15'],
      },
    },
    {
      name: 'local-screen-mobile-chromium',
      grep: /@screen/,
      use: {
        ...devices['Pixel 7'],
      },
    },
    {
      name: 'local-screen-mobile-webkit',
      grep: /@screen/,
      use: {
        ...devices['iPhone 15'],
      },
    },
    {
      name: 'local-signed-screen-chromium',
      grep: /@signed-screen/,
      use: {
        ...devices['Pixel 7'],
      },
    },
  ],
});
