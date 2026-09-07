import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile, writeFile, mkdir, rm, rename } from 'node:fs/promises';
import { dirname, resolve, join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';
import { createServer } from 'node:net';

const exec = promisify(execFile);
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const workerDir = join(root, 'apps/cloudflare-signal');
const pause = (ms) => new Promise((done) => setTimeout(done, ms));

export async function listObjects(api, account, namespace) {
  const objects = [];
  const seen = new Set();
  let cursor;
  for (let page = 0; page < 20; page++) {
    const query = new URLSearchParams({ limit: '1000', ...(cursor ? { cursor } : {}) });
    const result = await api(`/accounts/${account}/workers/durable_objects/namespaces/${namespace}/objects?${query}`);
    if (!Array.isArray(result.result)) throw new Error('Invalid namespace listing');
    if (!result.result.length) return objects;
    for (const object of result.result) {
      if (!/^[a-f0-9]{64}$/.test(object.id) || seen.has(object.id)) throw new Error('Invalid or repeated object listing');
      seen.add(object.id);
      objects.push(object);
    }
    if (objects.length > 2000) throw new Error('Migration exceeds the bounded 2000-object run');
    cursor = result.result_info?.cursor;
    if (!cursor) return objects;
  }
  throw new Error('Namespace pagination did not finish');
}

export async function inspectObject(call, object, dryRun, onPage = async () => {}) {
  let cursor;
  const pages = [];
  for (let page = 0; page < 100; page++) {
    const result = await call({ namespace: object.namespace, id: object.id, dryRun, ...(cursor ? { cursor } : {}) });
    if (!['scanned', 'invalid', 'deleted', 'fresh'].every((key) => Number.isSafeInteger(result[key]) && result[key] >= 0)) throw new Error('Invalid maintenance counts');
    pages.push(result);
    await onPage(result);
    if (!result.cursor) return pages;
    if (result.cursor === cursor) throw new Error('Maintenance cursor repeated');
    cursor = result.cursor;
  }
  throw new Error('Object exceeds the bounded migration page count');
}

async function freePort() {
  const server = createServer();
  await new Promise((done, fail) => { server.once('error', fail); server.listen(0, '127.0.0.1', done); });
  const port = server.address().port;
  await new Promise((done) => server.close(done));
  return port;
}

async function main() {
  const [phase, ledgerArg] = process.argv.slice(2);
  if (!['inventory', 'apply', 'verify'].includes(phase) || !ledgerArg) throw new Error('Usage: node ops/cache-retention/sweep.mjs inventory|apply|verify .cache/retention/ledger.json');
  const ledgerPath = resolve(root, ledgerArg);
  if (!ledgerPath.startsWith(join(root, '.cache') + '/')) throw new Error('Keep the private ledger under .cache/');
  const config = JSON.parse(await readFile(join(workerDir, 'wrangler.jsonc'), 'utf8'));
  const { stdout: sha } = await exec('git', ['rev-parse', 'HEAD'], { cwd: root });
  const { stdout: credentials } = await exec('pnpm', ['exec', 'wrangler', 'auth', 'token', '--json'], { cwd: workerDir });
  const { token } = JSON.parse(credentials);
  if (!token) throw new Error('Wrangler OAuth token unavailable');
  const api = async (path) => {
    const response = await fetch(`https://api.cloudflare.com/client/v4${path}`, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(30_000) });
    const body = await response.json();
    if (!response.ok || body.success !== true) throw new Error(`Cloudflare API failed (${response.status})`);
    return body;
  };
  const listing = await api(`/accounts/${config.account_id}/workers/durable_objects/namespaces`);
  const namespaces = listing.result.filter((ns) => ns.script === config.name && ['RelayHub', 'SignalingHub'].includes(ns.class));
  if (namespaces.length !== 2) throw new Error('Expected exactly the two Glasstunnel namespaces');
  let ledger;
  try { ledger = JSON.parse(await readFile(ledgerPath, 'utf8')); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (!ledger && phase === 'inventory') {
    ledger = { account: config.account_id, worker: config.name, source: sha.trim(), started: new Date().toISOString(), objects: [], inventoryComplete: false };
    for (const ns of namespaces) {
      const objects = await listObjects(api, config.account_id, ns.id);
      ledger.objects.push(...objects.map((o) => ({ id: o.id, stored: o.hasStoredData === true, namespace: ns.class === 'RelayHub' ? 'relay' : 'signal', namespaceId: ns.id })));
    }
  } else {
    if (!ledger || (phase !== 'inventory' && !ledger.inventoryComplete) || ledger.account !== config.account_id || ledger.worker !== config.name || ledger.source !== sha.trim()) throw new Error('The inventory must match this account, Worker and source SHA; complete inventory before apply/verify');
    if (ledger.objects.some((o) => !namespaces.some((ns) => ns.id === o.namespaceId && (ns.class === 'RelayHub' ? 'relay' : 'signal') === o.namespace))) throw new Error('Namespace scope changed');
    if (phase === 'verify') {
      for (const ns of namespaces) {
        for (const object of await listObjects(api, config.account_id, ns.id)) {
          if (!ledger.objects.some((o) => o.id === object.id)) ledger.objects.push({ id: object.id, namespaceId: ns.id, namespace: ns.class === 'RelayHub' ? 'relay' : 'signal' });
        }
      }
    }
  }
  await mkdir(dirname(ledgerPath), { recursive: true });
  const save = async () => {
    await writeFile(ledgerPath + '.tmp', JSON.stringify(ledger, null, 2) + '\n', { mode: 0o600 });
    await rename(ledgerPath + '.tmp', ledgerPath);
  };
  await save();
  const temporary = await mkdtemp(join(tmpdir(), 'glasstunnel-retention-'));
  const operatorToken = randomBytes(32).toString('hex');
  const port = await freePort();
  const localURL = `http://127.0.0.1:${port}`;
  await writeFile(join(temporary, '.dev.vars'), `OPERATOR_TOKEN=${operatorToken}\n`, { mode: 0o600 });
  const proxyConfig = join(temporary, 'wrangler.json');
  await writeFile(proxyConfig, JSON.stringify({ name: 'glasstunnel-retention-operator', main: join(root, 'ops/cache-retention/worker.ts'), compatibility_date: config.compatibility_date,
    account_id: config.account_id, workers_dev: false,
    durable_objects: { bindings: [{ name: 'RELAY_HUB', class_name: 'RelayHub', script_name: config.name }, { name: 'SIGNALING_HUB', class_name: 'SignalingHub', script_name: config.name }] },
  }));
  const child = spawn('pnpm', ['exec', 'wrangler', 'dev', '--remote', '--config', proxyConfig, '--ip', '127.0.0.1', '--port', String(port), '--show-interactive-dev-session=false'], { cwd: workerDir, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  let spawnError;
  child.on('error', (error) => { spawnError = error; });
  const exited = new Promise((done) => { child.once('exit', done); child.once('error', done); });
  let log = '';
  for (const stream of [child.stdout, child.stderr]) stream.on('data', (chunk) => { log = (log + String(chunk).replaceAll(operatorToken, '<redacted>')).slice(-20_000); });
  try {
    let ready = false;
    for (let i = 0; i < 90; i++) {
      if (child.exitCode !== null || spawnError) break;
      try { ready = (await fetch(localURL, { signal: AbortSignal.timeout(1000) })).status === 403; } catch { /* bounded startup */ }
      if (ready) break;
      await pause(1000);
    }
    if (!ready) throw new Error('Operator preview did not start; inspect the redacted local log');
    const call = async (body) => {
      const response = await fetch(localURL, { method: 'POST', headers: { Authorization: `Bearer ${operatorToken}` }, body: JSON.stringify(body), signal: AbortSignal.timeout(30_000) });
      if (!response.ok) throw new Error(`Maintenance failed (${response.status}); ledger preserved`);
      return response.json();
    };
    for (const object of ledger.objects) {
      if (phase === 'inventory' && object.inventory) continue;
      if (phase === 'apply' && object.applied) continue;
      if (phase === 'apply' && !object.inventory) throw new Error('Object has no prior inventory');
      const pages = await inspectObject(call, object, phase !== 'apply', async (result) => {
        if (phase === 'apply') { object.deleted = (object.deleted ?? 0) + result.deleted; await save(); }
      });
      object[phase] = pages;
      if (phase === 'apply') object.applied = true;
      await save();
    }
    if (phase === 'inventory') ledger.inventoryComplete = true;
    if (phase === 'verify') {
      ledger.verified = ledger.objects.every((o) => o.verify?.every((p) => p.invalid === 0 && p.active === true && p.cleanupFailures === 0));
    }
    ledger.updated = new Date().toISOString();
    await save();
    console.log(JSON.stringify({ phase, objects: ledger.objects.length, scanned: ledger.objects.reduce((n, o) => n + (o[phase] ?? []).reduce((s, p) => s + p.scanned, 0), 0), invalid: ledger.objects.reduce((n, o) => n + (o[phase] ?? []).reduce((s, p) => s + p.invalid, 0), 0), deleted: ledger.objects.reduce((n, o) => n + (o.deleted ?? 0), 0), verified: ledger.verified ?? false }));
    if (phase === 'verify' && !ledger.verified) throw new Error('Verification found remaining migration or cleanup work');
  } finally {
    // The owned process group includes pnpm, Wrangler and its local proxy.
    // Never search for or terminate another task's Wrangler process.
    if (child.pid) for (const signal of ['SIGINT', 'SIGTERM', 'SIGKILL']) {
      try { process.kill(-child.pid, signal); } catch (error) { if (error.code === 'ESRCH') break; throw error; }
      await Promise.race([exited, pause(2000)]);
    }
    await writeFile(ledgerPath + '.operator.log', log, { mode: 0o600 });
    await rm(temporary, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { console.error(error.message); process.exitCode = 1; });
}
