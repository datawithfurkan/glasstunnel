import { AgentStatus, type GridLayout, type RemoteApp } from '@glasstunnel/protocol';

const DIRECT_REMOTE_APP_IDS = new Set<string>([
  'screen',
  'terminal',
  'codex-cli',
  'cursor-agent',
  'claude-code',
  'gemini-cli',
  'opencode',
]);
export const SCREEN_STOP_CONFIRMATION_TIMEOUT_MS = 12_000;
export const RELAY_SCREEN_FRAME_FRESH_MS = 6_000;
export const RELAY_SCREEN_FRAME_FUTURE_TOLERANCE_MS = 30_000;

export function isDirectRemoteApp(appId: string): boolean {
  return DIRECT_REMOTE_APP_IDS.has(appId);
}

export function isProjectRemoteApp(app: RemoteApp): boolean {
  return !isDirectRemoteApp(app.remoteAppId);
}

export function fallbackRemoteAppsFromLayout(layout: GridLayout): RemoteApp[] {
  return layout.cells
    .filter((cell) => cell.agentId && cell.adapterKind !== 0)
    .map((cell) => ({
      remoteAppId: cell.agentId,
      displayName: cell.windowTitle || adapterDisplayName(cell.adapterKind),
      adapterKind: cell.adapterKind,
      agentId: cell.agentId,
      enabled: true,
      available: true,
      status: AgentStatus.Working,
      statusDetail: 'Syncing context',
      windowTitle: cell.windowTitle,
      applicationBundleId: cell.applicationBundleId,
      hasVideo: cell.videoEnabled,
    }));
}

export function isScreenStreamAvailable(apps: RemoteApp[]): boolean {
  const screen = apps.find((app) => app.remoteAppId === 'screen');
  return Boolean(
    screen?.enabled && screen.available !== false && isUsableScreenStatus(screen.status),
  );
}

export function shouldAcceptRelayScreenFrame(
  apps: RemoteApp[],
  frame: { agentId: string },
  pendingStop = false,
): boolean {
  if (pendingStop) return false;

  const screen = apps.find((app) => app.remoteAppId === 'screen');
  if (!screen?.enabled || screen.available === false || !isUsableScreenStatus(screen.status))
    return false;

  return frame.agentId === screen.agentId || frame.agentId === 'screen';
}

export function hasFreshRelayScreenFrameTimestamp(
  frame: { atUnixMs: number } | null | undefined,
  nowUnixMs: number,
): boolean {
  if (!frame) return false;
  const ageMs = nowUnixMs - frame.atUnixMs;
  return ageMs >= -RELAY_SCREEN_FRAME_FUTURE_TOLERANCE_MS && ageMs < RELAY_SCREEN_FRAME_FRESH_MS;
}

export function shouldCheckPendingScreenStop(
  requestedAtUnixMs: number,
  nowUnixMs: number,
  hostOnline: boolean | null,
): boolean {
  return (
    requestedAtUnixMs > 0 &&
    hostOnline === true &&
    nowUnixMs - requestedAtUnixMs >= SCREEN_STOP_CONFIRMATION_TIMEOUT_MS
  );
}

function isUsableScreenStatus(status: AgentStatus): boolean {
  return status !== AgentStatus.Error && status !== AgentStatus.Disconnected;
}

export function remoteAppsForCachedWorkspace(apps: RemoteApp[]): RemoteApp[] {
  return remoteAppsWithScreenSharingOff(apps);
}

export function remoteAppsWithScreenSharingOff(apps: RemoteApp[]): RemoteApp[] {
  return apps.map((app) =>
    app.remoteAppId === 'screen'
      ? {
          ...app,
          enabled: false,
          status: AgentStatus.Idle,
          statusDetail: 'Screen sharing off',
        }
      : app,
  );
}

export function selectActiveRemoteApp(
  apps: RemoteApp[],
  activeRemoteAppId: string | null,
): RemoteApp | null {
  if (apps.length === 0) return null;

  const current = activeRemoteAppId
    ? apps.find((app) => app.remoteAppId === activeRemoteAppId)
    : undefined;
  if (current) return current;

  return apps.find((app) => app.available) ?? apps[0];
}

function adapterDisplayName(kind: number): string {
  switch (kind) {
    case 1:
      return 'Mirror';
    case 2:
      return 'Cursor';
    case 3:
      return 'Claude Code';
    case 4:
      return 'Codex CLI';
    case 5:
      return 'OpenCode';
    case 7:
      return 'Gemini CLI';
    case 8:
      return 'Cursor Agent';
    default:
      return 'Remote app';
  }
}
