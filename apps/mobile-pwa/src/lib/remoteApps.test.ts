import { describe, expect, it } from 'vitest';
import { AgentStatus, type GridLayout, type RemoteApp } from '@glasstunnel/protocol';
import {
  fallbackRemoteAppsFromLayout,
  hasFreshRelayScreenFrameTimestamp,
  isScreenStreamAvailable,
  isDirectRemoteApp,
  isProjectRemoteApp,
  RELAY_SCREEN_FRAME_FUTURE_TOLERANCE_MS,
  RELAY_SCREEN_FRAME_FRESH_MS,
  remoteAppsForCachedWorkspace,
  remoteAppsWithScreenSharingOff,
  selectActiveRemoteApp,
  shouldAcceptRelayScreenFrame,
  shouldCheckPendingScreenStop,
  SCREEN_STOP_CONFIRMATION_TIMEOUT_MS,
} from './remoteApps';

describe('remote app model', () => {
  it('maps compatibility grid cells into visible remote apps', () => {
    const layout: GridLayout = {
      shape: 4,
      cells: [
        {
          position: { row: 0, col: 0, rowSpan: 1, colSpan: 1 },
          agentId: 'codex',
          windowTitle: 'Codex',
          applicationBundleId: 'com.openai.codex',
          adapterKind: 1,
          videoEnabled: true,
        },
        {
          position: { row: 0, col: 1, rowSpan: 1, colSpan: 1 },
          agentId: '',
          windowTitle: '',
          applicationBundleId: '',
          adapterKind: 0,
          videoEnabled: false,
        },
      ],
    };

    expect(fallbackRemoteAppsFromLayout(layout)).toEqual([
      expect.objectContaining({
        remoteAppId: 'codex',
        displayName: 'Codex',
        enabled: true,
        available: true,
        status: AgentStatus.Working,
        hasVideo: true,
      }),
    ]);
  });

  it('keeps the selected app when it is still present', () => {
    const apps = remoteApps([
      { remoteAppId: 'codex', enabled: true, available: true },
      { remoteAppId: 'cursor', enabled: true, available: true },
    ]);

    expect(selectActiveRemoteApp(apps, 'cursor')?.remoteAppId).toBe('cursor');
  });

  it('chooses the first ready app before unavailable apps', () => {
    const apps = remoteApps([
      { remoteAppId: 'claude-code', enabled: true, available: false },
      { remoteAppId: 'codex', enabled: true, available: true },
      { remoteAppId: 'cursor', enabled: false, available: true },
    ]);

    expect(selectActiveRemoteApp(apps, null)?.remoteAppId).toBe('codex');
  });

  it('returns the first app when no app is available', () => {
    const apps = remoteApps([{ remoteAppId: 'codex', enabled: false, available: false }]);

    expect(selectActiveRemoteApp(apps, null)?.remoteAppId).toBe('codex');
  });

  it('classifies Mac Screen, Terminal, and CLI surfaces as direct features', () => {
    const apps = remoteApps([
      { remoteAppId: 'screen', enabled: true, available: true },
      { remoteAppId: 'terminal', enabled: true, available: true },
      { remoteAppId: 'gemini-cli', enabled: true, available: true },
      { remoteAppId: 'cursor-agent', enabled: true, available: true },
      { remoteAppId: 'codex', enabled: true, available: true },
    ]);

    expect(isDirectRemoteApp('screen')).toBe(true);
    expect(isDirectRemoteApp('terminal')).toBe(true);
    expect(isDirectRemoteApp('gemini-cli')).toBe(true);
    expect(isDirectRemoteApp('cursor-agent')).toBe(true);
    expect(isDirectRemoteApp('codex')).toBe(false);
    expect(apps.filter(isProjectRemoteApp).map((app) => app.remoteAppId)).toEqual(['codex']);
  });

  it('only keeps screen media alive when Mac Screen is present, enabled, and available', () => {
    expect(isScreenStreamAvailable([])).toBe(false);
    expect(
      isScreenStreamAvailable(
        remoteApps([{ remoteAppId: 'screen', enabled: false, available: true }]),
      ),
    ).toBe(false);
    expect(
      isScreenStreamAvailable(
        remoteApps([{ remoteAppId: 'screen', enabled: true, available: false }]),
      ),
    ).toBe(false);
    expect(
      isScreenStreamAvailable(
        remoteApps([{ remoteAppId: 'screen', enabled: true, available: true }]),
      ),
    ).toBe(true);
  });

  it('turns off screen media when the Mac reports Screen as failed or disconnected', () => {
    expect(
      isScreenStreamAvailable(
        remoteApps([
          { remoteAppId: 'screen', enabled: true, available: true, status: AgentStatus.Error },
        ]),
      ),
    ).toBe(false);
    expect(
      isScreenStreamAvailable(
        remoteApps([
          {
            remoteAppId: 'screen',
            enabled: true,
            available: true,
            status: AgentStatus.Disconnected,
          },
        ]),
      ),
    ).toBe(false);
  });

  it('rejects stale relay frames when Mac Screen is not currently usable', () => {
    const frame = { agentId: 'screen' };

    expect(shouldAcceptRelayScreenFrame([], frame)).toBe(false);
    expect(
      shouldAcceptRelayScreenFrame(
        remoteApps([{ remoteAppId: 'screen', enabled: false, available: true }]),
        frame,
      ),
    ).toBe(false);
    expect(
      shouldAcceptRelayScreenFrame(
        remoteApps([{ remoteAppId: 'screen', enabled: true, available: false }]),
        frame,
      ),
    ).toBe(false);
    expect(
      shouldAcceptRelayScreenFrame(
        remoteApps([{ remoteAppId: 'screen', enabled: true, available: true }]),
        frame,
        true,
      ),
    ).toBe(false);
    expect(
      shouldAcceptRelayScreenFrame(
        remoteApps([
          { remoteAppId: 'screen', enabled: true, available: true, status: AgentStatus.Error },
        ]),
        frame,
      ),
    ).toBe(false);
  });

  it('accepts relay frames only for the current Mac Screen agent alias', () => {
    const apps = remoteApps([
      { remoteAppId: 'screen', enabled: true, available: true, agentId: 'mac-screen' },
    ]);

    expect(shouldAcceptRelayScreenFrame(apps, { agentId: 'mac-screen' })).toBe(true);
    expect(shouldAcceptRelayScreenFrame(apps, { agentId: 'screen' })).toBe(true);
    expect(shouldAcceptRelayScreenFrame(apps, { agentId: 'codex' })).toBe(false);
  });

  it('bounds relay screen frame freshness against stale and far-future timestamps', () => {
    const now = 20_000;

    expect(hasFreshRelayScreenFrameTimestamp(undefined, now)).toBe(false);
    expect(hasFreshRelayScreenFrameTimestamp({ atUnixMs: now - RELAY_SCREEN_FRAME_FRESH_MS + 1 }, now)).toBe(true);
    expect(hasFreshRelayScreenFrameTimestamp({ atUnixMs: now - RELAY_SCREEN_FRAME_FRESH_MS }, now)).toBe(false);
    expect(hasFreshRelayScreenFrameTimestamp({ atUnixMs: now + RELAY_SCREEN_FRAME_FUTURE_TOLERANCE_MS }, now)).toBe(true);
    expect(hasFreshRelayScreenFrameTimestamp({ atUnixMs: now + RELAY_SCREEN_FRAME_FUTURE_TOLERANCE_MS + 1 }, now)).toBe(false);
  });

  it('checks for unconfirmed screen stop only after the Mac has had time to respond', () => {
    const startedAt = 1_000;

    expect(
      shouldCheckPendingScreenStop(0, startedAt + SCREEN_STOP_CONFIRMATION_TIMEOUT_MS, true),
    ).toBe(false);
    expect(
      shouldCheckPendingScreenStop(
        startedAt,
        startedAt + SCREEN_STOP_CONFIRMATION_TIMEOUT_MS - 1,
        true,
      ),
    ).toBe(false);
    expect(
      shouldCheckPendingScreenStop(
        startedAt,
        startedAt + SCREEN_STOP_CONFIRMATION_TIMEOUT_MS,
        false,
      ),
    ).toBe(false);
    expect(
      shouldCheckPendingScreenStop(
        startedAt,
        startedAt + SCREEN_STOP_CONFIRMATION_TIMEOUT_MS,
        null,
      ),
    ).toBe(false);
    expect(
      shouldCheckPendingScreenStop(
        startedAt,
        startedAt + SCREEN_STOP_CONFIRMATION_TIMEOUT_MS,
        true,
      ),
    ).toBe(true);
  });

  it('does not restore cached Mac Screen as actively sharing', () => {
    const apps = remoteApps([
      { remoteAppId: 'screen', enabled: true, available: true },
      { remoteAppId: 'codex', enabled: true, available: true },
    ]);

    expect(remoteAppsForCachedWorkspace(apps)).toEqual([
      expect.objectContaining({
        remoteAppId: 'screen',
        enabled: false,
        status: AgentStatus.Idle,
        statusDetail: 'Screen sharing off',
      }),
      expect.objectContaining({
        remoteAppId: 'codex',
        enabled: true,
      }),
    ]);
  });

  it('normalizes Mac Screen to off while a stop is pending', () => {
    const apps = remoteApps([
      { remoteAppId: 'screen', enabled: true, available: true },
      { remoteAppId: 'codex', enabled: true, available: true },
    ]);

    const normalized = remoteAppsWithScreenSharingOff(apps);

    expect(normalized).toEqual([
      expect.objectContaining({
        remoteAppId: 'screen',
        enabled: false,
        status: AgentStatus.Idle,
        statusDetail: 'Screen sharing off',
      }),
      expect.objectContaining({
        remoteAppId: 'codex',
        enabled: true,
      }),
    ]);
    expect(apps[0].enabled).toBe(true);
  });
});

function remoteApps(
  partials: Array<
    Pick<RemoteApp, 'remoteAppId' | 'enabled' | 'available'> &
      Partial<Pick<RemoteApp, 'agentId' | 'status'>>
  >,
): RemoteApp[] {
  return partials.map((partial) => ({
    remoteAppId: partial.remoteAppId,
    displayName: partial.remoteAppId,
    adapterKind: 1,
    agentId: partial.agentId ?? partial.remoteAppId,
    enabled: partial.enabled,
    available: partial.available,
    status: partial.status ?? AgentStatus.Idle,
    statusDetail: '',
    windowTitle: '',
    applicationBundleId: '',
    hasVideo: true,
  }));
}
