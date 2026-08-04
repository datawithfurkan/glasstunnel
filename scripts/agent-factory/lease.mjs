import { open, readFile, readdir, unlink, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { mkdir } from 'node:fs/promises';
import { runProcess } from './process.mjs';

async function loadResources(paths) {
  const file = new URL('../../ops/agent-factory/policies/resources.json', import.meta.url);
  const policy = JSON.parse(await readFile(file, 'utf8'));
  return policy.resources;
}

function leaseFile(paths, resource) {
  if (!/^[a-z0-9-]+$/.test(resource)) throw new Error(`Invalid resource name: ${resource}`);
  return join(paths.leases, `${resource}.json`);
}

function parseBeadId(stdout) {
  const parsed = JSON.parse(stdout);
  const value = Array.isArray(parsed) ? parsed[0] : parsed;
  const id = value?.id ?? value?.issue?.id;
  if (!id) throw new Error('Beads did not return an audit bead ID');
  return id;
}

async function readLease(paths, resource) {
  return JSON.parse(await readFile(leaseFile(paths, resource), 'utf8'));
}

function assertOwner(lease, nodeId) {
  if (lease.nodeId !== nodeId) {
    throw new Error(`Resource ${lease.resource} is owned by a different node`);
  }
}

export async function acquireLease({
  resource,
  nodeId,
  holder,
  ttlSeconds,
  paths,
  runner = runProcess,
  now = new Date(),
}) {
  if (!/^[A-Za-z0-9-]+$/.test(nodeId)) throw new Error('Node ID must be alphanumeric with dashes');
  if (!holder?.trim()) throw new Error('Lease holder is required');
  const resources = await loadResources(paths);
  const definition = resources[resource];
  if (!definition) throw new Error(`Unknown factory resource: ${resource}`);
  const ttl = ttlSeconds ?? definition.defaultTtlSeconds;
  if (!Number.isInteger(ttl) || ttl <= definition.heartbeatSeconds) {
    throw new Error(`Lease TTL must exceed the ${definition.heartbeatSeconds}s heartbeat`);
  }

  await mkdir(paths.leases, { recursive: true, mode: 0o700 });
  const file = leaseFile(paths, resource);
  const acquiredAt = now.toISOString();
  const lease = {
    schema: 'glasstunnel.factory.lease.v1',
    resource,
    nodeId,
    holder,
    ttlSeconds: ttl,
    acquiredAt,
    heartbeatAt: acquiredAt,
    expiresAt: new Date(now.getTime() + ttl * 1000).toISOString(),
    auditBeadId: null,
  };

  let handle;
  try {
    handle = await open(file, 'wx', 0o600);
    await handle.writeFile(`${JSON.stringify(lease, null, 2)}\n`);
  } catch (error) {
    if (error.code === 'EEXIST') throw new Error(`Resource ${resource} is already leased`);
    throw error;
  } finally {
    await handle?.close();
  }

  const metadata = JSON.stringify({
    schema: lease.schema,
    resource,
    nodeId,
    holder,
    expiresAt: lease.expiresAt,
  });
  const result = await runner(
    'bd',
    [
      'create',
      '--type=gate',
      `--title=Resource lease: ${resource}`,
      '-l',
      `factory:resource-lease,factory:resource:${resource}`,
      '--metadata',
      metadata,
      '--json',
    ],
    { cwd: join(paths.rigs, 'glasstunnel'), timeoutMs: 30_000 },
  );

  if (result.code !== 0) {
    await unlink(file).catch(() => {});
    throw new Error(
      `Could not create Beads lease audit: ${result.stderr.trim() || 'unknown error'}`,
    );
  }

  try {
    lease.auditBeadId = parseBeadId(result.stdout);
    await writeFile(file, `${JSON.stringify(lease, null, 2)}\n`, { mode: 0o600 });
    return lease;
  } catch (error) {
    await unlink(file).catch(() => {});
    throw error;
  }
}

export async function heartbeatLease({ resource, nodeId, paths, now = new Date() }) {
  const lease = await readLease(paths, resource);
  assertOwner(lease, nodeId);
  lease.heartbeatAt = now.toISOString();
  lease.expiresAt = new Date(now.getTime() + lease.ttlSeconds * 1000).toISOString();
  await writeFile(leaseFile(paths, resource), `${JSON.stringify(lease, null, 2)}\n`, {
    mode: 0o600,
  });
  return lease;
}

export async function releaseLease({ resource, nodeId, paths, runner = runProcess }) {
  const lease = await readLease(paths, resource);
  assertOwner(lease, nodeId);
  const result = await runner(
    'bd',
    [
      'close',
      lease.auditBeadId,
      '--reason',
      `Resource ${resource} released by ${nodeId}`,
      '--json',
    ],
    { cwd: join(paths.rigs, 'glasstunnel'), timeoutMs: 30_000 },
  );
  if (result.code !== 0)
    throw new Error(`Could not close Beads lease audit: ${result.stderr.trim()}`);
  await unlink(leaseFile(paths, resource));
}

export async function recoverExpiredLease({
  resource,
  paths,
  runner = runProcess,
  now = new Date(),
  humanApproved = false,
}) {
  const resources = await loadResources(paths);
  const definition = resources[resource];
  if (!definition) throw new Error(`Unknown factory resource: ${resource}`);
  if (definition.humanGate && !humanApproved) {
    throw new Error(`Recovery of ${resource} requires --human-approved`);
  }
  const lease = await readLease(paths, resource);
  if (new Date(lease.expiresAt).getTime() > now.getTime()) {
    throw new Error(`Resource ${resource} has not expired`);
  }
  const result = await runner(
    'bd',
    [
      'close',
      lease.auditBeadId,
      '--reason',
      `Expired resource lease recovered at ${now.toISOString()}`,
      '--json',
    ],
    { cwd: join(paths.rigs, 'glasstunnel'), timeoutMs: 30_000 },
  );
  if (result.code !== 0)
    throw new Error(`Could not close expired Beads lease audit: ${result.stderr.trim()}`);
  await unlink(leaseFile(paths, resource));
  return { resource, recoveredNodeId: lease.nodeId, recoveryCommand: definition.recoveryCommand };
}

export async function listLeases(paths) {
  const names = await readdir(paths.leases).catch((error) => {
    if (error.code === 'ENOENT') return [];
    throw error;
  });
  const leases = [];
  for (const name of names.filter((entry) => entry.endsWith('.json')).sort()) {
    leases.push(JSON.parse(await readFile(join(paths.leases, name), 'utf8')));
  }
  return leases;
}
