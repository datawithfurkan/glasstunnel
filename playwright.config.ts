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
      name: 'local-account-mobile-chromium',
      grep: /@account/,
      use: {
        ...devices['Pixel 7'],
      },
    },
    {
      name: 'local-codex-cli-mobile-chromium',
      grep: /@codex-cli-account/,
      use: {
        ...devices['Pixel 7'],
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
