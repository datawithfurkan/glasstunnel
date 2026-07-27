import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { promisify } from 'node:util';

import { ensureRuntimeDirectories, labConfig } from './config.mjs';
import {
  managedProcessStatus,
  readManifest,
  spawnManagedService,
  stopManagedService,
  stopManifestServices,
  writeManifest,
} from './processes.mjs';
import { bootstrapSupabase, defaultRunCommand, resetSupabase } from './supabase.mjs';

const execFileAsync = promisify(execFile);

function envLine(name, value) {
  return `${name}=${JSON.stringify(String(value))}`;
}

export function writeWorkerEnvironment(config, supabase) {
  ensureRuntimeDirectories(config);
  const contents = [
    envLine('PUBLIC_APP_URL', config.urls.pwa),
    envLine('SUPABASE_URL', supabase.apiUrl),
    envLine('SUPABASE_SERVICE_ROLE_KEY', supabase.serviceRoleKey),
    '',
  ].join('\n');
  writeFileSync(config.files.workerEnv, contents, { encoding: 'utf8', mode: 0o600 });
  return config.files.workerEnv;
}

export function workerServiceDefinition(config) {
  return {
    name: 'worker',
    command: join(config.root, 'apps/cloudflare-signal/node_modules/.bin/wrangler'),
    args: [
      'dev',
      '--cwd',
      join(config.root, 'apps/cloudflare-signal'),
      '--config',
      'wrangler.jsonc',
      '--env-file',
      config.files.workerEnv,
      '--ip',
      '127.0.0.1',
      '--port',
      String(config.ports.worker),
      '--persist-to',
      config.paths.workerState,
      '--local',
      '--show-interactive-dev-session=false',
    ],
    env: { NO_COLOR: '1' },
    cwd: config.root,
    healthUrl: `${config.urls.worker}/health`,
  };
}

export function pwaServiceDefinition(config, supabase) {
  return {
    name: 'pwa',
    command: 'pnpm',
    args: [
      '--dir',
      join(config.root, 'apps/mobile-pwa'),
      'exec',
      'vite',
      '--host',
      '127.0.0.1',
      '--port',
      String(config.ports.pwa),
      '--strictPort',
    ],
    env: {
      VITE_PUBLIC_APP_URL: config.urls.pwa,
      VITE_SIGNALING_URL: config.urls.signaling,
      VITE_SUPABASE_URL: supabase.apiUrl,
      VITE_SUPABASE_ANON_KEY: supabase.anonKey,
    },
    cwd: config.root,
    healthUrl: config.urls.pwa,
  };
}

export function hostServiceDefinition(
  config,
  { lifetimeSeconds = 3_600, label = 'Glasstunnel local lab' } = {},
) {
  return {
    name: 'host',
    command: 'swift',
    args: [
      'run',
      '--package-path',
      join(config.root, 'apps/host-macos'),
      '--scratch-path',
      config.paths.swiftScratch,
      'TerminalLiveHostHarness',
    ],
    env: {
      GLASSTUNNEL_DEV: '1',
      GLASSTUNNEL_DEV_DEVICE_KEY_FILE: config.files.deviceKey,
      GT_TERMINAL_LIVE_SIGNALING_URL: config.urls.signaling,
      GT_TERMINAL_LIVE_HOST_LABEL: label,
      GT_TERMINAL_LIVE_HOST_SECONDS: String(lifetimeSeconds),
      GT_TERMINAL_LIVE_SYNTHETIC_SCREEN: '1',
    },
    cwd: config.root,
    label,
  };
}

export function parseHostMetadata(log) {
  const harnessError = /^HARNESS_ERROR\s+(.+)$/m.exec(log);
  if (harnessError) throw new Error(`Swift host harness failed: ${harnessError[1]}`);

  const deviceId = /^HOST_DEVICE_ID\s+(\S+)$/m.exec(log)?.[1];
  const linkCode = /^LINK_CODE\s+(\S+)$/m.exec(log)?.[1];
  return deviceId && linkCode ? { deviceId, linkCode } : null;
}

export async function startHostHarness({
  config = ensureRuntimeDirectories(labConfig()),
  runId = randomUUID(),
  lifetimeSeconds = 3_600,
  startupTimeoutMs = 180_000,
  spawnService = spawnManagedService,
} = {}) {
  const definition = hostServiceDefinition(config, { lifetimeSeconds });
  const service = await spawnService(config, { ...definition, runId });
  const deadline = Date.now() + startupTimeoutMs;

  try {
    while (Date.now() < deadline) {
      const log = existsSync(service.logPath) ? readFileSync(service.logPath, 'utf8') : '';
      const metadata = parseHostMetadata(log);
      if (metadata) return { ...metadata, label: definition.label, service };

      const status = await managedProcessStatus(service);
      if (!status.alive) {
        throw new Error(`Swift host harness exited before linking. See ${service.logPath}.`);
      }
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    throw new Error(`Timed out waiting for the Swift host harness. See ${service.logPath}.`);
  } catch (error) {
    await stopManagedService(service).catch(() => {});
    throw error;
  }
}

export function signedMacLaunchDefinition(config) {
  const appPath = config.files.macApp;
  return {
    command: 'bash',
    args: [join(config.root, 'scripts/dev-app.sh')],
    cwd: config.root,
    env: {
      GLASSTUNNEL_DEV: '1',
      GLASSTUNNEL_DEV_DEVICE_KEY_FILE: config.files.deviceKey,
      GLASSTUNNEL_DEVICE_REGISTRY_FILE: config.files.deviceRegistry,
      GLASSTUNNEL_WEB_APP_URL: config.urls.pwa,
      GLASSTUNNEL_SIGNALING_URL: config.urls.signaling,
      GLASSTUNNEL_KEYCHAIN_SUFFIX: 'lab',
      GLASSTUNNEL_SWIFT_SCRATCH_PATH: config.paths.swiftScratch,
      GLASSTUNNEL_DEV_APP_PATH: appPath,
      GLASSTUNNEL_DEV_BUNDLE_ID: 'io.glasstunnel.host.lab',
      GLASSTUNNEL_DEV_DISPLAY_NAME: 'Glasstunnel Lab',
    },
  };
}

export async function stopSignedMacApp({
  config = ensureRuntimeDirectories(labConfig()),
  runCommand = defaultRunCommand,
} = {}) {
  const executable = join(
    config.files.macApp,
    'Contents',
    'MacOS',
    'GlassTunnel',
  );
  let output;
  try {
    output = await runCommand('/usr/bin/pgrep', ['-x', 'GlassTunnel'], { cwd: config.root });
  } catch {
    return false;
  }

  let stopped = false;
  for (const pid of String(output.stdout ?? '')
    .split(/\s+/)
    .filter(Boolean)) {
    try {
      const process = await runCommand('/bin/ps', ['-p', pid, '-o', 'command='], {
        cwd: config.root,
      });
      if (String(process.stdout ?? '').trim() !== executable) continue;
      await runCommand('/bin/kill', ['-TERM', pid], { cwd: config.root });
      stopped = true;
    } catch {
      // A process may exit between discovery and inspection.
    }
  }
  return stopped;
}

export async function findPortOwners(port) {
  try {
    const { stdout } = await execFileAsync(
      '/usr/sbin/lsof',
      ['-nP', `-iTCP:${port}`, '-sTCP:LISTEN', '-t'],
      { encoding: 'utf8' },
    );
    return [...new Set(stdout.split(/\s+/).filter(Boolean).map(Number))];
  } catch (error) {
    if (error.code === 1) return [];
    throw error;
  }
}

export async function assertPortsAvailable(config, { findOwners = findPortOwners } = {}) {
  for (const [name, port] of [
    ['PWA', config.ports.pwa],
    ['Worker', config.ports.worker],
  ]) {
    const owners = await findOwners(port);
    if (owners.length > 0) {
      throw new Error(
        `${name} port ${port} is owned by PID ${owners.join(', ')}; refusing to replace an unknown process.`,
      );
    }
  }
}

export async function waitForHttp(
  url,
  { timeoutMs = 30_000, intervalMs = 200, fetchImpl = fetch } = {},
) {
  const deadline = Date.now() + timeoutMs;
  let lastError;

  while (Date.now() < deadline) {
    try {
      const response = await fetchImpl(url);
      if (response.ok) return response;
      lastError = new Error(`${url} returned HTTP ${response.status}.`);
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }

  throw new Error(`Timed out waiting for ${url}: ${lastError?.message ?? 'no response'}`);
}

async function cleanupFailedStart(config, manifest, runCommand) {
  if (manifest.services.length > 0) {
    await stopManifestServices(config).catch(() => {});
  } else {
    rmSync(config.files.manifest, { force: true });
  }
  if (manifest.startedSupabaseByLab) {
    await runCommand('supabase', ['stop'], { cwd: config.root }).catch(() => {});
  }
}

export async function startCoreLab({
  host = false,
  config = ensureRuntimeDirectories(labConfig()),
  bootstrap = bootstrapSupabase,
  spawnService = spawnManagedService,
  waitHealth = waitForHttp,
  findOwners = findPortOwners,
  runCommand = defaultRunCommand,
  hostStarter = startHostHarness,
} = {}) {
  const existing = readManifest(config);
  if (existing) {
    const statuses = await Promise.all(existing.services.map(managedProcessStatus));
    if (statuses.some((status) => status.alive)) {
      throw new Error(
        'The local lab is already running. Use `pnpm lab:status` or `pnpm lab:down`.',
      );
    }
    rmSync(config.files.manifest, { force: true });
  }

  await assertPortsAvailable(config, { findOwners });
  const supabase = await bootstrap({ config, runCommand });
  const runId = randomUUID();
  const manifest = {
    version: 1,
    runId,
    createdAt: new Date().toISOString(),
    startedSupabaseByLab: supabase.startedByLab,
    services: [],
  };
  writeManifest(config, manifest);

  try {
    writeWorkerEnvironment(config, supabase);
    for (const definition of [
      workerServiceDefinition(config),
      pwaServiceDefinition(config, supabase),
    ]) {
      const service = await spawnService(config, { ...definition, runId });
      manifest.services.push(service);
      writeManifest(config, manifest);
      await waitHealth(definition.healthUrl);
    }

    if (host) {
      const hostResult = await hostStarter({ config, runId, manifest });
      manifest.services.push(hostResult.service);
      manifest.host = {
        deviceId: hostResult.deviceId,
        linkCode: hostResult.linkCode,
        label: hostResult.label,
      };
      writeManifest(config, manifest);
    }

    return labStatus({ config });
  } catch (error) {
    await cleanupFailedStart(config, manifest, runCommand);
    throw error;
  }
}

export async function labStatus({ config = labConfig(), fetchImpl = fetch } = {}) {
  const manifest = readManifest(config);
  if (!manifest) return { running: false, services: [] };

  const services = [];
  for (const service of manifest.services) {
    const processStatus = await managedProcessStatus(service);
    const healthUrl =
      service.name === 'worker'
        ? `${config.urls.worker}/health`
        : service.name === 'pwa'
          ? config.urls.pwa
          : null;
    let healthy = processStatus.alive && processStatus.owned;
    if (healthy && healthUrl) {
      try {
        healthy = (await fetchImpl(healthUrl)).ok;
      } catch {
        healthy = false;
      }
    }
    services.push({
      name: service.name,
      pid: service.pid,
      alive: processStatus.alive,
      owned: processStatus.owned,
      healthy,
      logPath: service.logPath,
    });
  }

  return {
    running: services.length > 0 && services.every((service) => service.healthy),
    runId: manifest.runId,
    urls: config.urls,
    host: manifest.host,
    services,
  };
}

export async function stopLab({
  config = labConfig(),
  runCommand = defaultRunCommand,
  stopMacApp = stopSignedMacApp,
} = {}) {
  const macAppStopped = await stopMacApp({ config, runCommand });
  const manifest = readManifest(config);
  if (!manifest) {
    rmSync(config.files.workerEnv, { force: true });
    return { stopped: macAppStopped, macAppStopped, services: [] };
  }
  const services = await stopManifestServices(config);
  if (manifest.startedSupabaseByLab) {
    await runCommand('supabase', ['stop'], { cwd: config.root });
  }
  rmSync(config.files.workerEnv, { force: true });
  return { stopped: true, macAppStopped, services };
}

export async function resetLab({
  config = ensureRuntimeDirectories(labConfig()),
  runCommand = defaultRunCommand,
  stopMacApp = stopSignedMacApp,
  resetDatabase = resetSupabase,
  bootstrap = bootstrapSupabase,
} = {}) {
  await stopLab({ config, runCommand, stopMacApp });
  const resetStatus = await resetDatabase({ root: config.root, runCommand });
  try {
    const supabase = await bootstrap({ config, runCommand });
    rmSync(config.paths.workerState, { recursive: true, force: true });
    ensureRuntimeDirectories(config);
    return { reset: true, email: supabase.email };
  } finally {
    if (resetStatus.startedByLab) {
      await runCommand('supabase', ['stop'], { cwd: config.root });
    }
  }
}

const TOOL_VERSION_ARGS = {
  node: ['--version'],
  pnpm: ['--version'],
  docker: ['--version'],
  supabase: ['--version'],
  wrangler: ['--version'],
  swift: ['--version'],
  xcodebuild: ['-version'],
};

function commandOutput(result) {
  return [result.stdout, result.stderr]
    .map((value) => String(value ?? '').trim())
    .filter(Boolean)
    .join('\n');
}

async function defaultBrowserExecutables() {
  const { chromium, webkit } = await import('@playwright/test');
  return {
    chromium: chromium.executablePath(),
    webkit: webkit.executablePath(),
  };
}

async function inspectTool(command, { config, runCommand, pathExists }) {
  const workspacePath =
    command === 'wrangler'
      ? join(config.root, 'apps/cloudflare-signal/node_modules/.bin/wrangler')
      : join(config.root, 'node_modules', '.bin', command);
  let path = pathExists(workspacePath) ? workspacePath : '';
  if (!path) {
    try {
      path = commandOutput(await runCommand('/usr/bin/which', [command], { cwd: config.root }));
    } catch {
      // Availability is reported below.
    }
  }

  if (!path) return { available: false };

  try {
    const result = await runCommand(path, TOOL_VERSION_ARGS[command], { cwd: config.root });
    return { available: true, path, version: commandOutput(result) };
  } catch (error) {
    return { available: false, path, version: null, error: error.message };
  }
}

export async function runDoctor({
  config = labConfig(),
  runCommand = defaultRunCommand,
  browserExecutables = defaultBrowserExecutables,
  pathExists = existsSync,
  findOwners = findPortOwners,
  processStatus = managedProcessStatus,
} = {}) {
  const tools = {};
  for (const command of Object.keys(TOOL_VERSION_ARGS)) {
    tools[command] = await inspectTool(command, { config, runCommand, pathExists });
  }

  let docker;
  try {
    const result = await runCommand('docker', ['info', '--format', '{{.ServerVersion}}'], {
      cwd: config.root,
    });
    docker = { ready: true, version: commandOutput(result) };
  } catch (error) {
    docker = { ready: false, error: error.message };
  }

  const browsers = {};
  try {
    const executables = await browserExecutables();
    for (const name of ['chromium', 'webkit']) {
      const path = executables[name];
      browsers[name] = { available: Boolean(path && pathExists(path)), path };
    }
  } catch (error) {
    for (const name of ['chromium', 'webkit']) {
      browsers[name] = { available: false, error: error.message };
    }
  }

  let signing;
  try {
    const result = await runCommand(
      '/usr/bin/security',
      ['find-identity', '-v', '-p', 'codesigning'],
      { cwd: config.root },
    );
    const output = commandOutput(result);
    const identity = /^\s*\d+\)\s+[A-F0-9]+\s+"([^"]+)"/m.exec(output)?.[1];
    signing = identity ? { stable: true, identity } : { stable: false, fallback: 'ad-hoc' };
  } catch (error) {
    signing = { stable: false, fallback: 'ad-hoc', error: error.message };
  }

  const ports = {};
  for (const name of ['pwa', 'worker', 'supabase']) {
    const port = config.ports[name];
    const owners = await findOwners(port);
    ports[name] = { port, owners, available: owners.length === 0 };
  }

  const storedManifest = readManifest(config);
  const serviceStatuses = storedManifest
    ? await Promise.all(
        storedManifest.services.map(async (service) => ({
          name: service.name,
          pid: service.pid,
          ...(await processStatus(service)),
        })),
      )
    : [];
  const manifest = {
    present: Boolean(storedManifest),
    stale:
      Boolean(storedManifest) &&
      (serviceStatuses.length === 0 ||
        serviceStatuses.some((status) => !status.alive || !status.owned)),
    runId: storedManifest?.runId,
    services: serviceStatuses,
  };

  const actions = [];
  for (const [name, tool] of Object.entries(tools)) {
    if (!tool.available) actions.push(`Install or repair ${name}, then rerun \`pnpm lab:doctor\`.`);
  }
  if (!docker.ready) actions.push('Start Docker Desktop, then rerun `pnpm lab:doctor`.');
  for (const [name, browser] of Object.entries(browsers)) {
    if (!browser.available)
      actions.push(`Install Playwright ${name} with \`pnpm exec playwright install ${name}\`.`);
  }
  if (manifest.stale) actions.push('Remove stale lab ownership safely with `pnpm lab:down`.');
  for (const name of ['pwa', 'worker']) {
    if (!ports[name].available) {
      actions.push(
        `Free ${name.toUpperCase()} port ${ports[name].port}; the lab will not replace another process.`,
      );
    }
  }
  if (!signing.stable) {
    actions.push(
      'No stable code-signing identity found; signed Mac testing will use the documented local fallback.',
    );
  }

  const requiredToolsReady = Object.values(tools).every((tool) => tool.available);
  const browsersReady = Object.values(browsers).every((browser) => browser.available);
  const corePortsReady = ports.pwa.available && ports.worker.available;

  return {
    ok: requiredToolsReady && docker.ready && browsersReady && corePortsReady && !manifest.stale,
    canonicalRoot: config.root,
    tools,
    docker,
    browsers,
    signing,
    ports,
    manifest,
    actions,
  };
}

export async function launchSignedMacApp({
  config = ensureRuntimeDirectories(labConfig()),
  runCommand = defaultRunCommand,
} = {}) {
  const definition = signedMacLaunchDefinition(config);
  await runCommand(definition.command, definition.args, {
    cwd: definition.cwd,
    env: { ...process.env, ...definition.env },
  });
  return {
    launched: true,
    appPath: definition.env.GLASSTUNNEL_DEV_APP_PATH,
    urls: config.urls,
  };
}
