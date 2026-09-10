import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { CURRENT_PROTOCOL_VERSION, type Hello } from '@glasstunnel/protocol';
import { generateDeviceKeypair } from '@glasstunnel/shared-crypto';
import { RelayConnection } from './RelayConnection';
import type { PairedHost } from '../lib/store';

describe('RelayConnection host presence gating', () => {
  beforeEach(() => {
    vi.stubGlobal('WebSocket', { OPEN: 1 });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('does not send commands when only the browser relay socket is authenticated', async () => {
    const { relay, send } = await connectedRelay({ hostOnline: null });

    const delivered = relay.sendUserInput({
      agentId: 'claude-code',
      text: 'Start Claude',
      submitOnSend: true,
    });

    expect(delivered).toBe(false);
    expect(send).not.toHaveBeenCalled();
  });

  it('sends commands only after live host presence or live state arrives', async () => {
    const { relay, send } = await connectedRelay({ hostOnline: null });

    await handleRelayMessage(relay, {
      type: 'relay_hello',
      cached: false,
      hello: helloFixture(),
    });

    const delivered = relay.sendUserInput({
      agentId: 'codex',
      text: 'Continue',
      submitOnSend: true,
    });

    expect(delivered).toBe(true);
    expect(send).toHaveBeenCalledTimes(1);
    expect(JSON.parse(send.mock.calls[0]?.[0] as string)).toMatchObject({
      type: 'relay_command',
      command: {
        body: {
          kind: 'userInput',
          userInput: {
            agentId: 'codex',
            text: 'Continue',
            submitOnSend: true,
          },
        },
      },
    });
  });

  it('renews its authorization in place with a fresh account token when the relay asks', async () => {
    const getAccessToken = vi.fn(async () => 'fresh-token');
    const { relay, send } = await connectedRelay({ hostOnline: true, getAccessToken });

    await handleRelayMessage(relay, { type: 'relay_reauth_required', expires_at: Date.now() + 60_000 });

    await vi.waitFor(() => expect(send).toHaveBeenCalledTimes(1));
    expect(getAccessToken).toHaveBeenCalledTimes(1);
    expect(JSON.parse(send.mock.calls[0]?.[0] as string)).toMatchObject({
      type: 'relay_reauth',
      access_token: 'fresh-token',
    });
  });

  it('retries a renewal the relay could not complete', async () => {
    vi.useFakeTimers();
    try {
      const { relay, send } = await connectedRelay({ hostOnline: true, getAccessToken: async () => 'fresh-token' });

      await handleRelayMessage(relay, { type: 'relay_reauth_failed', retry: true });
      expect(send).not.toHaveBeenCalled();
      await vi.advanceTimersByTimeAsync(5_000);

      expect(send).toHaveBeenCalledTimes(1);
      expect(JSON.parse(send.mock.calls[0]?.[0] as string)).toMatchObject({ type: 'relay_reauth' });
    } finally {
      vi.useRealTimers();
    }
  });

  it('blocks commands again after host_offline relay errors', async () => {
    const { relay, send } = await connectedRelay({ hostOnline: true });

    await handleRelayMessage(relay, {
      type: 'relay_error',
      code: 'host_offline',
      message: 'Mac offline.',
    });

    const delivered = relay.sendRemoteAppAction({
      remoteAppId: 'terminal',
      action: 'launch',
    });

    expect(delivered).toBe(false);
    expect(send).not.toHaveBeenCalled();
  });

  it('sends screen quality with remote app start commands', async () => {
    const { relay, send } = await connectedRelay({ hostOnline: true });

    const delivered = relay.sendRemoteAppAction({
      remoteAppId: 'screen',
      action: 'start',
      screenQuality: 'readable',
    });

    expect(delivered).toBe(true);
    expect(JSON.parse(send.mock.calls[0]?.[0] as string)).toMatchObject({
      type: 'relay_command',
      command: {
        body: {
          kind: 'remoteAppActionRequest',
          remoteAppActionRequest: {
            remoteAppId: 'screen',
            action: 'start',
            screenQuality: 'readable',
          },
        },
      },
    });
  });

  it('sends agent runtime settings commands', async () => {
    const { relay, send } = await connectedRelay({ hostOnline: true });

    const delivered = relay.sendRuntimeSettingsUpdate({
      agentId: 'codex-cli',
      modelId: 'gpt-5.5',
      reasoningEffort: 'xhigh',
      fastMode: true,
    });

    expect(delivered).toBe(true);
    expect(JSON.parse(send.mock.calls[0]?.[0] as string)).toMatchObject({
      type: 'relay_command',
      command: {
        body: {
          kind: 'agentRuntimeSettingsUpdate',
          agentRuntimeSettingsUpdate: {
            agentId: 'codex-cli',
            modelId: 'gpt-5.5',
            reasoningEffort: 'xhigh',
            fastMode: true,
          },
        },
      },
    });
  });

  it('delivers relay screen frames and marks the host online', async () => {
    const onScreenFrame = vi.fn();
    const onState = vi.fn();
    const { relay } = await connectedRelay({ hostOnline: null, onScreenFrame, onState });

    await handleRelayMessage(relay, {
      type: 'relay_screen_frame',
      agentId: 'screen',
      mimeType: 'image/jpeg',
      width: 720,
      height: 450,
      bytes: 'abc123',
      sequence: 7,
      atUnixMs: 1234,
    });

    expect(onState).toHaveBeenCalledWith({ connected: true, online: true });
    expect(onScreenFrame).toHaveBeenCalledWith(
      expect.objectContaining({
        agentId: 'screen',
        width: 720,
        bytes: 'abc123',
      }),
    );
    expect(relay.isHostOnline).toBe(true);
  });
});

async function connectedRelay(options: {
  hostOnline: boolean | null;
  onScreenFrame?: ConstructorParameters<typeof RelayConnection>[0]['onScreenFrame'];
  onState?: ConstructorParameters<typeof RelayConnection>[0]['onState'];
  getAccessToken?: ConstructorParameters<typeof RelayConnection>[0]['getAccessToken'];
}) {
  const keypair = await generateDeviceKeypair();
  const host: PairedHost = {
    deviceId: 'gt-host',
    publicKeyB64: 'host-public-key',
    label: 'Test Mac',
    signalingUrl: 'wss://signaling.glasstunnel.test/signal',
    pairedAtUnixMs: 1,
  };
  const relay = new RelayConnection({
    keypair,
    host,
    accessToken: 'test-token',
    getAccessToken: options.getAccessToken,
    onScreenFrame: options.onScreenFrame,
    onState: options.onState,
  });
  const send = vi.fn();
  Object.assign(relay as unknown as RelayConnectionInternals, {
    authenticated: true,
    hostOnline: options.hostOnline,
    ws: {
      readyState: 1,
      send,
    },
  });
  return { relay, send };
}

async function handleRelayMessage(relay: RelayConnection, message: Record<string, unknown>) {
  await (relay as unknown as RelayConnectionInternals).handleMessage(
    JSON.stringify(message),
    () => {},
  );
}

function helloFixture(): Hello {
  return {
    hostVersion: 'test',
    hostOsVersion: 'macOS',
    hostDeviceLabel: 'Test Mac',
    supportedAdapters: ['codex'],
    currentLayout: { shape: 1, cells: [] },
    protocolVersion: CURRENT_PROTOCOL_VERSION,
    remoteApps: [],
  };
}

interface RelayConnectionInternals {
  authenticated: boolean;
  hostOnline: boolean | null;
  ws: { readyState: number; send: ReturnType<typeof vi.fn> } | null;
  handleMessage(raw: string, resolveAuth: (deviceId: string) => void): Promise<void>;
}
