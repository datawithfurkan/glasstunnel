#!/usr/bin/env node
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { AgentStatus, DEFAULT_SIGNALING_URL, encodeDataChannelMessageJson } from '../packages/protocol/dist/index.js';
import { base64FromBytes, bytesFromBase64, generateDeviceKeypair, sign } from '../packages/shared-crypto/dist/index.js';

const usage = `Usage:
  GT_TERMINAL_LIVE_ACCESS_TOKEN=<supabase-access-token> pnpm qa:terminal:live

Optional:
  GT_TERMINAL_LIVE_HOST_DEVICE_ID=<host-device-id>
  GT_TERMINAL_LIVE_SIGNALING_URL=wss://signaling.glasstunnel.io/signal
  GT_TERMINAL_LIVE_ARTIFACT_DIR=/tmp/glasstunnel-terminal-live
  GT_TERMINAL_LIVE_TIMEOUT_MS=60000

This diagnostic proves the hosted relay Terminal path only. It does not prove
rendered Safari/Chrome UI or physical-phone behavior.`;

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log(usage);
  process.exit(0);
}

const accessToken = process.env.GT_TERMINAL_LIVE_ACCESS_TOKEN?.trim();
if (!accessToken) {
  console.error('GT_TERMINAL_LIVE_ACCESS_TOKEN is required.');
  console.error('Pass a disposable test-account access token. Do not commit or log it.');
  process.exit(2);
}

const signalingUrl = process.env.GT_TERMINAL_LIVE_SIGNALING_URL || DEFAULT_SIGNALING_URL;
const artifactDir = process.env.GT_TERMINAL_LIVE_ARTIFACT_DIR || '/tmp/glasstunnel-terminal-live';
const timeoutMs = Number(process.env.GT_TERMINAL_LIVE_TIMEOUT_MS || 60_000);
const hostDeviceId = process.env.GT_TERMINAL_LIVE_HOST_DEVICE_ID?.trim();

const startedAt = Date.now();
const keypair = await generateDeviceKeypair();
const browserLabel = `Terminal live diagnostic ${new Date().toISOString()}`;
const markerBase = `GT_TERMINAL_LIVE_${startedAt}`;
const commandMarker = `${markerBase}_COMMAND`;
const recoveryMarker = `${markerBase}_RECOVERY`;
const snapshots = [];
const statusDetails = new Set();
const remoteAppStates = [];
let presenceOnline = false;
let authenticated = false;
let host;
let hostCandidates = {
  total: 0,
  online: 0,
  trusted: 0,
  onlineTrusted: 0,
};
let socket;

try {
  const hosts = await registerBrowserDevice({
    deviceId: keypair.deviceId,
    publicKeyB64: base64FromBytes(keypair.publicKey),
    label: browserLabel,
  });
  hostCandidates = summarizeHosts(hosts);
  host = chooseHost(hosts);
  if (!host) {
    throw new Error(hostSelectionError(hosts));
  }
  if (host.online !== true) throw new Error(`Selected host is offline: ${host.label || host.deviceId}`);
  if (host.trusted !== true) throw new Error(`Selected host is not trusted: ${host.label || host.deviceId}`);

  socket = await connectRelay(host);
  await waitFor(() => authenticated && presenceOnline, 'relay authentication and online presence');
  await waitFor(() => terminalRemoteApp()?.available === true, 'Terminal remote app availability');

  sendCommand({
    kind: 'remoteAppActionRequest',
    remoteAppActionRequest: { remoteAppId: 'terminal', action: 'start' },
  });
  await waitFor(() => terminalStarted(), 'Terminal started/ready snapshot');

  sendTerminalInput(`printf '${commandMarker}\\n'\n`);
  await waitFor(() => snapshotTextIncludes(commandMarker), 'Terminal command marker output');

  sendTerminalInput('sleep 20\n');
  await waitFor(() => terminalIsWorking(), 'long-running Terminal command state');

  sendCommand({
    kind: 'interruptRequest',
    interruptRequest: { agentId: 'terminal' },
  });
  await waitFor(() => statusDetails.has('interrupt sent') || !terminalIsWorking(), 'Terminal interrupt acknowledgement');

  sendTerminalInput(`printf '${recoveryMarker}\\n'\n`);
  await waitFor(() => snapshotTextIncludes(recoveryMarker), 'Terminal recovery command marker output');

  const artifact = await writeArtifact(true);
  console.log(`Result: passed; hosted relay Terminal command, output, interrupt, and recovery verified.`);
  console.log(`Artifact: ${artifact}`);
} catch (error) {
  const artifact = await writeArtifact(false, error);
  console.error(`Result: failed; ${error instanceof Error ? error.message : String(error)}`);
  console.error(`Artifact: ${artifact}`);
  process.exitCode = 1;
} finally {
  try {
    socket?.close();
  } catch {
    // best-effort cleanup only
  }
}

function apiBaseUrl() {
  return signalingUrl.replace(/^ws/i, 'http').replace(/\/signal\/?$/, '');
}

async function registerBrowserDevice(input) {
  const response = await fetch(`${apiBaseUrl()}/account/device/register`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${accessToken}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      ...input,
      kind: 'browser',
      platform: 'node-terminal-live-diagnostic',
    }),
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(`register browser device failed with ${response.status}: ${safeError(payload)}`);
  }
  return Array.isArray(payload.hosts) ? payload.hosts : [];
}

function chooseHost(hosts) {
  if (hostDeviceId) return hosts.find((candidate) => candidate.deviceId === hostDeviceId);
  const eligible = hosts.filter((candidate) => candidate.online === true && candidate.trusted === true);
  if (eligible.length === 1) return eligible[0];
  return undefined;
}

function summarizeHosts(hosts) {
  const values = Array.isArray(hosts) ? hosts : [];
  return {
    total: values.length,
    online: values.filter((candidate) => candidate.online === true).length,
    trusted: values.filter((candidate) => candidate.trusted === true).length,
    onlineTrusted: values.filter((candidate) => candidate.online === true && candidate.trusted === true).length,
  };
}

function hostSelectionError(hosts) {
  const summary = summarizeHosts(hosts);
  if (hostDeviceId) {
    return `Configured host was not returned for this account. Hosts: total=${summary.total}, online=${summary.online}, trusted=${summary.trusted}, onlineTrusted=${summary.onlineTrusted}.`;
  }
  if (summary.total === 0) {
    return 'No Mac hosts are linked to this account. Sign in to the Mac app with the same disposable test account, then rerun.';
  }
  if (summary.onlineTrusted === 0) {
    return `No online trusted Mac host found for this account. Hosts: total=${summary.total}, online=${summary.online}, trusted=${summary.trusted}, onlineTrusted=${summary.onlineTrusted}.`;
  }
  return `Multiple online trusted hosts found (${summary.onlineTrusted}). Set GT_TERMINAL_LIVE_HOST_DEVICE_ID to choose one.`;
}

async function connectRelay(selectedHost) {
  const relayUrl = new URL(selectedHost.signalingUrl || signalingUrl);
  relayUrl.pathname = '/relay';
  relayUrl.searchParams.set('host_device_id', selectedHost.deviceId);

  const ws = new WebSocket(relayUrl.toString());
  ws.addEventListener('message', (event) => {
    void handleRelayMessage(String(event.data));
  });

  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('relay WebSocket open timed out')), 10_000);
    ws.addEventListener('open', () => {
      clearTimeout(timer);
      resolve();
    }, { once: true });
    ws.addEventListener('error', () => {
      clearTimeout(timer);
      reject(new Error('relay WebSocket failed to connect'));
    }, { once: true });
  });
  return ws;
}

async function handleRelayMessage(raw) {
  let message;
  try {
    message = JSON.parse(raw);
  } catch {
    return;
  }

  switch (message.type) {
    case 'server_hello':
      await authenticate(message.nonce);
      return;
    case 'auth_ok':
      authenticated = true;
      return;
    case 'relay_presence':
      presenceOnline = message.online === true;
      return;
    case 'relay_remote_apps':
      for (const app of message.remoteApps ?? []) {
        if (app.remoteAppId === 'terminal') {
          remoteAppStates.push({
            enabled: app.enabled === true,
            available: app.available === true,
            status: app.status,
            statusDetail: app.statusDetail,
            cached: message.cached === true,
          });
        }
      }
      return;
    case 'relay_agent_state':
      if (message.snapshot?.agentId === 'terminal' || message.snapshot?.remoteAppId === 'terminal') {
        snapshots.push(message.snapshot);
        if (typeof message.snapshot.statusDetail === 'string' && message.snapshot.statusDetail) {
          statusDetails.add(message.snapshot.statusDetail);
        }
      }
      return;
    case 'relay_error':
      if (message.code === 'host_offline') presenceOnline = false;
      return;
    default:
      return;
  }
}

async function authenticate(nonceB64) {
  const nonce = bytesFromBase64(nonceB64);
  const signature = await sign(nonce, keypair.privateKey);
  socket.send(JSON.stringify({
    type: 'client_auth',
    device_id: keypair.deviceId,
    public_key: base64FromBytes(keypair.publicKey),
    signature: base64FromBytes(signature),
    role: 'client',
    device_info: 'node-terminal-live-diagnostic',
    access_token: accessToken,
  }));
}

function sendTerminalInput(text) {
  sendCommand({
    kind: 'userInput',
    userInput: { agentId: 'terminal', text, submitOnSend: true },
  });
}

function sendCommand(body) {
  if (!socket || socket.readyState !== WebSocket.OPEN) {
    throw new Error('relay WebSocket is not open');
  }
  if (!authenticated || !presenceOnline) {
    throw new Error('relay is not authenticated with an online host');
  }
  const encoded = encodeDataChannelMessageJson({
    messageId: crypto.randomUUID(),
    atUnixMs: Date.now(),
    body,
  });
  socket.send(JSON.stringify({
    type: 'relay_command',
    command: JSON.parse(encoded),
    at: Date.now(),
  }));
}

async function waitFor(predicate, label) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  throw new Error(`Timed out waiting for ${label}`);
}

function terminalRemoteApp() {
  for (let i = remoteAppStates.length - 1; i >= 0; i -= 1) {
    return remoteAppStates[i];
  }
  return undefined;
}

function latestTerminalSnapshot() {
  return snapshots[snapshots.length - 1];
}

function terminalIsWorking() {
  const snapshot = latestTerminalSnapshot();
  return snapshot?.status === AgentStatus.Working || snapshot?.statusDetail === 'running command';
}

function terminalStarted() {
  const snapshot = latestTerminalSnapshot();
  const detail = String(snapshot?.statusDetail ?? '').toLowerCase();
  return detail === 'started' || detail === 'ready' || statusDetails.has('started');
}

function snapshotTextIncludes(marker) {
  return snapshots.some((snapshot) =>
    (snapshot.recentMessages ?? []).some((message) => String(message.text ?? '').includes(marker)),
  );
}

function safeError(payload) {
  if (payload && typeof payload.error === 'string') return payload.error;
  return 'unknown error';
}

async function writeArtifact(ok, error) {
  await mkdir(artifactDir, { recursive: true });
  const artifactPath = join(artifactDir, `terminal-live-relay-${new Date().toISOString().replace(/[:.]/g, '-')}.json`);
  const latest = latestTerminalSnapshot();
  const artifact = {
    ok,
    artifactKind: 'sanitized-live-terminal-relay-diagnostic',
    commit: await currentCommit(),
    evidenceBoundary: 'hosted relay only; not rendered Safari/Chrome UI and not physical-phone evidence',
    host: host ? {
      label: host.label,
      online: host.online === true,
      trusted: host.trusted === true,
    } : null,
    hostCandidates,
    relay: {
      authenticated,
      presenceOnline,
    },
    terminal: {
      available: terminalRemoteApp()?.available === true,
      commandDelivery: snapshotTextIncludes(commandMarker),
      outputStreaming: snapshotTextIncludes(commandMarker),
      longRunningCommandObserved: statusDetails.has('running command') || snapshots.some((snapshot) => snapshot.status === AgentStatus.Working),
      interruptSent: statusDetails.has('interrupt sent'),
      recoveryCommandAccepted: snapshotTextIncludes(recoveryMarker),
      latestStatus: latest?.status,
      latestStatusDetail: latest?.statusDetail,
      statusDetails: Array.from(statusDetails),
      snapshotCount: snapshots.length,
    },
    markers: {
      commandMarkerSeen: snapshotTextIncludes(commandMarker),
      recoveryMarkerSeen: snapshotTextIncludes(recoveryMarker),
    },
    error: error instanceof Error ? error.message : error ? String(error) : undefined,
    elapsedMs: Date.now() - startedAt,
  };
  await writeFile(artifactPath, `${JSON.stringify(artifact, null, 2)}\n`, 'utf8');
  return artifactPath;
}

async function currentCommit() {
  try {
    const { execFile } = await import('node:child_process');
    return await new Promise((resolve) => {
      execFile('git', ['rev-parse', '--short', 'HEAD'], (error, stdout) => {
        resolve(error ? 'unknown' : stdout.trim());
      });
    });
  } catch {
    return 'unknown';
  }
}
