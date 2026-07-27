import {
  AdapterKind,
  AgentStatus,
  ChatRole,
  CURRENT_PROTOCOL_VERSION,
  GridShape,
  type AgentStateSnapshot,
  type Hello,
  type RemoteApp,
} from '@glasstunnel/protocol';
import type { AccountHost } from '../lib/accountApi';
import { useAppStore, type AppState, type AuthenticatedUser, type PairedHost } from '../lib/store';

export type WorkspaceFixtureId =
  | 'hosts-empty'
  | 'hosts-mixed'
  | 'workspace-empty'
  | 'workspace-single-app'
  | 'workspace-multi-app'
  | 'workspace-all-apps'
  | 'workspace-screen-offline'
  | 'workspace-screen-stopping'
  | 'workspace-terminal-stopped'
  | 'workspace-terminal-running'
  | 'workspace-codex-cli-stopped'
  | 'workspace-codex-cli-starting'
  | 'workspace-codex-cli-running'
  | 'workspace-codex-target-unverified'
  | 'workspace-cursor-generated-labels'
  | 'workspace-cursor-agent-running'
  | 'workspace-opencode-running'
  | 'workspace-gemini-cli-running'
  | 'workspace-claude-code-running'
  | 'workspace-offline-cached';

const FIXTURE_PARAM = 'gtFixture';
const ENABLED = import.meta.env.DEV || import.meta.env.MODE === 'test';

export function currentWorkspaceFixtureId(): WorkspaceFixtureId | null {
  if (!ENABLED || typeof window === 'undefined') return null;
  const value = new URL(window.location.href).searchParams.get(FIXTURE_PARAM);
  return isWorkspaceFixtureId(value) ? value : null;
}

export function isWorkspaceFixtureEnabled(): boolean {
  return currentWorkspaceFixtureId() !== null;
}

export function applyWorkspaceFixture(): boolean {
  const fixtureId = currentWorkspaceFixtureId();
  if (!fixtureId) return false;
  useAppStore.setState(workspaceFixtureState(fixtureId));
  return true;
}

export function currentWorkspaceFixtureInitialAppId(): 'codex' | 'screen' | 'terminal' | null {
  return workspaceFixtureInitialAppId(currentWorkspaceFixtureId());
}

export function workspaceFixtureInitialAppId(
  fixtureId: WorkspaceFixtureId | null,
): 'codex' | 'screen' | 'terminal' | null {
  return fixtureId === 'workspace-screen-offline' || fixtureId === 'workspace-screen-stopping'
    ? 'screen'
    : fixtureId === 'workspace-terminal-stopped' || fixtureId === 'workspace-terminal-running'
      ? 'terminal'
      : fixtureId === 'workspace-codex-target-unverified'
        ? 'codex'
    : null;
}

export function workspaceFixtureState(fixtureId: WorkspaceFixtureId): Partial<AppState> {
  if (fixtureId === 'hosts-empty' || fixtureId === 'hosts-mixed') {
    return hostSelectionFixtureState(fixtureId);
  }

  const remoteApps =
    fixtureId === 'workspace-all-apps'
      ? [
          screenApp(),
          codexApp(),
          claudeCodeApp(),
          cursorApp(),
          cursorAgentApp(),
          geminiCliApp(),
          openCodeApp(),
          codexCliApp(),
          terminalApp(),
        ]
      : fixtureId === 'workspace-terminal-running'
        ? [
            screenApp(),
            codexApp(),
            terminalApp({
              status: AgentStatus.Working,
              statusDetail: 'running command',
            }),
          ]
      : fixtureId === 'workspace-terminal-stopped'
        ? [
            screenApp(),
            codexApp(),
            terminalApp({
              enabled: false,
              status: AgentStatus.Idle,
              statusDetail: 'Stopped',
            }),
          ]
      : fixtureId === 'workspace-codex-cli-stopped'
        ? [
            screenApp(),
            codexApp(),
            codexCliApp({
              status: AgentStatus.Done,
              statusDetail: 'process exited (0)',
            }),
            terminalApp(),
          ]
      : fixtureId === 'workspace-codex-cli-starting'
        ? [
            screenApp(),
            codexApp(),
            codexCliApp({
              status: AgentStatus.Working,
              statusDetail: 'Starting',
            }),
            terminalApp(),
          ]
      : fixtureId === 'workspace-codex-cli-running'
        ? [
            screenApp(),
            codexApp(),
            codexCliApp({
              status: AgentStatus.Working,
              statusDetail: 'Working',
            }),
            terminalApp(),
          ]
      : fixtureId === 'workspace-codex-target-unverified'
        ? [screenApp(), codexApp(), terminalApp()]
      : fixtureId === 'workspace-cursor-generated-labels'
        ? [
            screenApp(),
            codexApp(),
            cursorApp({
              available: true,
              status: AgentStatus.Idle,
              statusDetail: 'Ready',
              windowTitle: 'Cursor',
            }),
            terminalApp(),
          ]
      : fixtureId === 'workspace-cursor-agent-running'
        ? [
            screenApp(),
            codexApp(),
            cursorAgentApp({
              status: AgentStatus.Working,
              statusDetail: 'Working',
            }),
            terminalApp(),
          ]
      : fixtureId === 'workspace-opencode-running'
        ? [
            screenApp(),
            codexApp(),
            openCodeApp({
              status: AgentStatus.Working,
              statusDetail: 'Working',
            }),
            terminalApp(),
          ]
      : fixtureId === 'workspace-gemini-cli-running'
        ? [
            screenApp(),
            codexApp(),
            geminiCliApp({
              status: AgentStatus.Working,
              statusDetail: 'Working',
            }),
            terminalApp(),
          ]
      : fixtureId === 'workspace-claude-code-running'
        ? [
            screenApp(),
            codexApp(),
            claudeCodeApp({
              status: AgentStatus.Working,
              statusDetail: 'Working',
            }),
            terminalApp(),
          ]
      : fixtureId === 'workspace-screen-stopping'
        ? [
            screenApp({
              enabled: true,
              status: AgentStatus.Working,
              statusDetail: 'Stopping stream',
            }),
            codexApp(),
            terminalApp(),
          ]
      : fixtureId === 'workspace-screen-offline'
        ? [screenApp({ enabled: true }), codexApp(), terminalApp()]
      : fixtureId === 'workspace-multi-app'
        ? [screenApp(), codexApp(), cursorApp(), terminalApp()]
        : [screenApp(), codexApp(), terminalApp()];
  const agents: Record<string, AgentStateSnapshot> =
    fixtureId === 'workspace-empty'
      ? {}
      : {
          codex: codexSnapshot(),
        };
  if (fixtureId === 'workspace-screen-stopping') {
    agents.screen = screenStoppingSnapshot();
  }
  if (fixtureId === 'workspace-multi-app') {
    agents.cursor = cursorSnapshot();
  }
  if (fixtureId === 'workspace-all-apps') {
    agents['claude-code'] = cliSnapshot('claude-code', 'Claude Code', AdapterKind.ClaudeCode);
    agents.cursor = cursorSnapshot();
    agents['cursor-agent'] = cliSnapshot('cursor-agent', 'Cursor Agent', AdapterKind.CursorAgent);
    agents['gemini-cli'] = cliSnapshot('gemini-cli', 'Gemini CLI', AdapterKind.GeminiCli);
    agents.opencode = cliSnapshot('opencode', 'OpenCode', AdapterKind.OpenCode);
    agents['codex-cli'] = cliSnapshot('codex-cli', 'Codex CLI', AdapterKind.CodexCli);
  }
  if (fixtureId === 'workspace-terminal-running') {
    agents.terminal = terminalRunningSnapshot();
  }
  if (fixtureId === 'workspace-codex-cli-stopped') {
    agents['codex-cli'] = cliSnapshot('codex-cli', 'Codex CLI', AdapterKind.CodexCli, {
      status: AgentStatus.Done,
      statusDetail: 'process exited (0)',
    });
  }
  if (fixtureId === 'workspace-codex-cli-starting') {
    agents['codex-cli'] = cliSnapshot('codex-cli', 'Codex CLI', AdapterKind.CodexCli, {
      status: AgentStatus.Working,
      statusDetail: 'Starting',
      lastActivityUnixMs: Date.now() - 30_000,
      recentMessages: [
        {
          messageId: 'codex-cli-starting-system',
          role: ChatRole.System,
          text: 'Starting Codex CLI on this Mac.',
          atUnixMs: Date.now() - 30_000,
          redacted: false,
          pendingToolCalls: [],
        },
      ],
    });
  }
  if (fixtureId === 'workspace-codex-cli-running') {
    agents['codex-cli'] = runningCliSnapshot(
      'codex-cli',
      'Codex CLI',
      AdapterKind.CodexCli,
      '>_ OpenAI Codex\nmodel: gpt-5.5 xhigh\n\nI found one focused next fix.',
    );
  }
  if (fixtureId === 'workspace-codex-target-unverified') {
    agents.codex = codexTargetUnverifiedSnapshot();
  }
  if (fixtureId === 'workspace-cursor-generated-labels') {
    agents.cursor = cursorGeneratedLabelSnapshot();
  }
  if (fixtureId === 'workspace-cursor-agent-running') {
    agents['cursor-agent'] = runningCliSnapshot(
      'cursor-agent',
      'Cursor Agent',
      AdapterKind.CursorAgent,
      'Cursor Agent\nmodel: gpt-5.4-nano-none\n\nI found one focused next fix.',
    );
  }
  if (fixtureId === 'workspace-opencode-running') {
    agents.opencode = runningCliSnapshot(
      'opencode',
      'OpenCode',
      AdapterKind.OpenCode,
      'OpenCode v1.17.7\nprovider/model: opencode/nemotron-3-ultra-free\n\nReady for the next prompt.',
      {
        availableTargets: openCodeThreadTargets(),
      },
    );
  }
  if (fixtureId === 'workspace-gemini-cli-running') {
    agents['gemini-cli'] = runningCliSnapshot(
      'gemini-cli',
      'Gemini CLI',
      AdapterKind.GeminiCli,
      'Gemini CLI 0.46.0\nmodel: gemini-2.5-pro\n\nDrafted a concise implementation plan.',
    );
  }
  if (fixtureId === 'workspace-claude-code-running') {
    agents['claude-code'] = runningCliSnapshot(
      'claude-code',
      'Claude Code',
      AdapterKind.ClaudeCode,
      'Claude Code 2.1.178\nmodel: sonnet\n\nReady to continue coding.',
    );
  }

  return {
    route: 'workspace',
    locked: false,
    readOnlyMode: false,
    pairedHost: fixtureHost(),
    availableHosts: [],
    user: fixtureUser(),
    authConfigured: true,
    layout: fixtureLayout(),
    hostHello: fixtureHello(remoteApps),
    workspaceHostDeviceId: 'fixture-mac-mini',
    remoteApps,
    agents,
    videoStreams: {},
    relayScreenFrames: {},
    relayHostOnline: fixtureId === 'workspace-offline-cached' || fixtureId === 'workspace-screen-offline' ? false : true,
    error:
      fixtureId === 'workspace-offline-cached' || fixtureId === 'workspace-screen-offline'
        ? 'Mac offline. Open Glasstunnel on the Mac, then retry.'
        : null,
    ...(fixtureId === 'workspace-screen-stopping' ||
    fixtureId === 'workspace-terminal-stopped' ||
    fixtureId === 'workspace-codex-cli-stopped' ||
    fixtureId === 'workspace-codex-cli-starting'
      ? { requestRemoteAppAction: () => true }
      : {}),
  };
}

function isWorkspaceFixtureId(value: string | null): value is WorkspaceFixtureId {
  return (
    value === 'hosts-empty' ||
    value === 'hosts-mixed' ||
    value === 'workspace-empty' ||
    value === 'workspace-single-app' ||
    value === 'workspace-multi-app' ||
    value === 'workspace-all-apps' ||
    value === 'workspace-screen-offline' ||
    value === 'workspace-screen-stopping' ||
    value === 'workspace-terminal-stopped' ||
    value === 'workspace-terminal-running' ||
    value === 'workspace-codex-cli-stopped' ||
    value === 'workspace-codex-cli-starting' ||
    value === 'workspace-codex-cli-running' ||
    value === 'workspace-codex-target-unverified' ||
    value === 'workspace-cursor-generated-labels' ||
    value === 'workspace-cursor-agent-running' ||
    value === 'workspace-opencode-running' ||
    value === 'workspace-gemini-cli-running' ||
    value === 'workspace-claude-code-running' ||
    value === 'workspace-offline-cached'
  );
}

function hostSelectionFixtureState(fixtureId: 'hosts-empty' | 'hosts-mixed'): Partial<AppState> {
  const hosts = fixtureId === 'hosts-mixed' ? fixtureAccountHosts() : [];

  return {
    route: 'hosts',
    locked: false,
    readOnlyMode: false,
    pairedHost: null,
    availableHosts: hosts,
    user: fixtureUser(),
    authConfigured: true,
    layout: null,
    hostHello: null,
    workspaceHostDeviceId: null,
    remoteApps: [],
    agents: {},
    videoStreams: {},
    relayScreenFrames: {},
    relayHostOnline: null,
    error: null,
    refreshHosts: async () => undefined,
    claimHostLinkCode: async () => hosts[0] ?? fixtureAccountHost('fixture-new-mac', 'New Mac', true, true),
    chooseHost: async (hostDeviceId: string) => {
      const selected = hosts.find((host) => host.deviceId === hostDeviceId);
      if (!selected) return;
      useAppStore.setState({
        pairedHost: {
          deviceId: selected.deviceId,
          publicKeyB64: selected.publicKeyB64,
          label: selected.label,
          signalingUrl: selected.signalingUrl,
          turnUrl: selected.turnUrl,
          turnUsername: selected.turnUsername,
          turnPassword: selected.turnPassword,
          pairedAtUnixMs: selected.pairedAtUnixMs,
        },
        workspaceHostDeviceId: null,
        relayHostOnline: selected.online,
        route: 'workspace',
      });
    },
  };
}

function fixtureAccountHosts(): AccountHost[] {
  return [
    fixtureAccountHost('fixture-mac-online', "Test Mac", true, true, 1_781_312_200_000),
    fixtureAccountHost('fixture-mac-offline', 'MacBook Pro', false, true, 1_781_300_000_000),
    fixtureAccountHost('fixture-mac-preparing', 'Office Mac', true, false),
  ];
}

function fixtureAccountHost(
  deviceId: string,
  label: string,
  online: boolean,
  trusted: boolean,
  lastSeenAtUnixMs?: number,
): AccountHost {
  return {
    deviceId,
    publicKeyB64: `${deviceId}-public-key`,
    label,
    signalingUrl: 'https://fixture.invalid/signal',
    online,
    trusted,
    pairedAtUnixMs: 1_781_312_000_000,
    lastSeenAtUnixMs,
  };
}

function fixtureHost(): PairedHost {
  return {
    deviceId: 'fixture-mac-mini',
    publicKeyB64: 'fixture-public-key',
    label: 'Fixture Mac mini',
    signalingUrl: 'https://fixture.invalid/signal',
    pairedAtUnixMs: 1_781_312_000_000,
  };
}

function fixtureUser(): AuthenticatedUser {
  return {
    id: 'fixture-user',
    email: 'fixture@glasstunnel.test',
    displayName: 'Fixture User',
  };
}

function fixtureHello(remoteApps: RemoteApp[]): Hello {
  return {
    hostVersion: '0.1.0-dev',
    hostOsVersion: 'macOS 15.5',
    hostDeviceLabel: 'Fixture Mac mini',
    supportedAdapters: remoteApps.map((app) => app.remoteAppId),
    currentLayout: fixtureLayout(),
    remoteApps,
    protocolVersion: CURRENT_PROTOCOL_VERSION,
  };
}

function fixtureLayout() {
  return {
    shape: GridShape.OneByOne,
    cells: [],
  };
}

function screenApp(overrides: Partial<RemoteApp> = {}): RemoteApp {
  return {
    remoteAppId: 'screen',
    displayName: 'Mac Screen',
    adapterKind: AdapterKind.Mirror,
    agentId: 'screen',
    enabled: false,
    available: true,
    status: AgentStatus.Idle,
    statusDetail: 'Screen sharing off',
    windowTitle: '',
    applicationBundleId: 'io.glasstunnel.host',
    hasVideo: true,
    ...overrides,
  };
}

function codexApp(): RemoteApp {
  return {
    remoteAppId: 'codex',
    displayName: 'Codex',
    adapterKind: AdapterKind.Mirror,
    agentId: 'codex',
    enabled: true,
    available: true,
    status: AgentStatus.Idle,
    statusDetail: 'Ready from web',
    windowTitle: 'Codex',
    applicationBundleId: 'com.openai.codex',
    hasVideo: false,
  };
}

function cursorApp(overrides: Partial<RemoteApp> = {}): RemoteApp {
  return {
    remoteAppId: 'cursor',
    displayName: 'Cursor',
    adapterKind: AdapterKind.Cursor,
    agentId: 'cursor',
    enabled: true,
    available: false,
    status: AgentStatus.Disconnected,
    statusDetail: 'Open Cursor on this Mac',
    windowTitle: '',
    applicationBundleId: 'com.todesktop.230313mzl4w4u92',
    hasVideo: false,
    ...overrides,
  };
}

function claudeCodeApp(overrides: Partial<RemoteApp> = {}): RemoteApp {
  return cliApp('claude-code', 'Claude Code', AdapterKind.ClaudeCode, 'Ready', overrides);
}

function openCodeApp(overrides: Partial<RemoteApp> = {}): RemoteApp {
  return cliApp('opencode', 'OpenCode', AdapterKind.OpenCode, 'Ready', overrides);
}

function geminiCliApp(overrides: Partial<RemoteApp> = {}): RemoteApp {
  return cliApp('gemini-cli', 'Gemini CLI', AdapterKind.GeminiCli, 'Ready', overrides);
}

function codexCliApp(overrides: Partial<RemoteApp> = {}): RemoteApp {
  return cliApp('codex-cli', 'Codex CLI', AdapterKind.CodexCli, 'Ready', overrides);
}

function cursorAgentApp(overrides: Partial<RemoteApp> = {}): RemoteApp {
  return cliApp('cursor-agent', 'Cursor Agent', AdapterKind.CursorAgent, 'Ready', overrides);
}

function terminalApp(overrides: Partial<RemoteApp> = {}): RemoteApp {
  return {
    remoteAppId: 'terminal',
    displayName: 'Terminal',
    adapterKind: AdapterKind.Terminal,
    agentId: 'terminal',
    enabled: true,
    available: true,
    status: AgentStatus.Idle,
    statusDetail: 'Ready',
    windowTitle: '',
    applicationBundleId: '',
    hasVideo: false,
    ...overrides,
  };
}

function cliApp(
  remoteAppId: 'claude-code' | 'cursor-agent' | 'gemini-cli' | 'opencode' | 'codex-cli',
  displayName: string,
  adapterKind: AdapterKind,
  statusDetail: string,
  overrides: Partial<RemoteApp> = {},
): RemoteApp {
  return {
    remoteAppId,
    displayName,
    adapterKind,
    agentId: remoteAppId,
    enabled: true,
    available: true,
    status: AgentStatus.Idle,
    statusDetail,
    windowTitle: '',
    applicationBundleId: '',
    hasVideo: false,
    ...overrides,
  };
}

function codexSnapshot(): AgentStateSnapshot {
  return {
    agentId: 'codex',
    agentLabel: 'Codex',
    adapterKind: AdapterKind.Mirror,
    status: AgentStatus.Idle,
    statusDetail: 'Ready',
    recentMessages: [
      {
        messageId: 'fixture-codex-message',
        role: ChatRole.Assistant,
        text: 'Ready to continue.',
        atUnixMs: 1_781_312_100_000,
        redacted: false,
        pendingToolCalls: [],
      },
    ],
    lastActivityUnixMs: 1_781_312_100_000,
    position: { row: 0, col: 0, rowSpan: 1, colSpan: 1 },
    hasVideoTrack: false,
    remoteAppId: 'codex',
    availableTargets: [
      {
        targetId: 'fixture-thread-glasstunnel',
        label: 'glasstunnel',
        subtitle: '~/Documents/GitHub2/glasstunnel',
        selected: true,
        projectId: '/Users/developer/Documents/GitHub2/glasstunnel',
        projectLabel: 'glasstunnel',
        projectPath: '/Users/developer/Documents/GitHub2/glasstunnel',
        threadId: 'fixture-thread-glasstunnel',
        threadLabel: 'Glasstunnel 1',
        targetKind: 'thread',
        lastActivityUnixMs: 1_781_312_100_000,
        isActive: true,
      },
      {
        targetId: 'fixture-project-empty',
        label: 'empty-project',
        subtitle: '~/Documents/GitHub2/empty-project',
        selected: false,
        projectId: '/Users/developer/Documents/GitHub2/empty-project',
        projectLabel: 'empty-project',
        projectPath: '/Users/developer/Documents/GitHub2/empty-project',
        threadId: 'fixture-project-empty',
        targetKind: 'project',
        lastActivityUnixMs: 1_781_312_000_000,
      },
      {
        targetId: 'fixture-loose-chat',
        label: 'Loose chat',
        subtitle: 'Standalone chat',
        selected: false,
        threadId: 'fixture-loose-chat',
        threadLabel: 'Loose chat',
        targetKind: 'thread',
        lastActivityUnixMs: 1_781_311_900_000,
      },
    ],
  };
}

function codexTargetUnverifiedSnapshot(): AgentStateSnapshot {
  const snapshot = codexSnapshot();
  return {
    ...snapshot,
    agentLabel: 'Glasstunnel 1',
    availableTargets: (snapshot.availableTargets ?? []).map((target) =>
      target.selected ? { ...target, isActive: false } : target,
    ),
  };
}

function screenStoppingSnapshot(): AgentStateSnapshot {
  return {
    agentId: 'screen',
    agentLabel: 'Mac Screen',
    adapterKind: AdapterKind.Mirror,
    status: AgentStatus.Working,
    statusDetail: 'Stopping stream',
    recentMessages: [],
    lastActivityUnixMs: 1_781_312_150_000,
    position: { row: 0, col: 0, rowSpan: 1, colSpan: 1 },
    hasVideoTrack: false,
    remoteAppId: 'screen',
    availableTargets: [],
  };
}

function cursorSnapshot(): AgentStateSnapshot {
  return {
    agentId: 'cursor',
    agentLabel: 'Cursor',
    adapterKind: AdapterKind.Cursor,
    status: AgentStatus.Disconnected,
    statusDetail: 'Open Cursor on this Mac',
    recentMessages: [],
    lastActivityUnixMs: 0,
    position: { row: 0, col: 0, rowSpan: 1, colSpan: 1 },
    hasVideoTrack: false,
    remoteAppId: 'cursor',
    availableTargets: [],
  };
}

function cursorGeneratedLabelSnapshot(): AgentStateSnapshot {
  return {
    agentId: 'cursor',
    agentLabel: 'Cursor',
    adapterKind: AdapterKind.Cursor,
    status: AgentStatus.Idle,
    statusDetail: 'Ready',
    recentMessages: [
      {
        messageId: 'fixture-cursor-user',
        role: ChatRole.User,
        text: 'GT_CURSOR_FIXTURE_PROMPT',
        atUnixMs: 1_781_312_170_000,
        redacted: false,
        pendingToolCalls: [],
      },
      {
        messageId: 'fixture-cursor-assistant',
        role: ChatRole.Assistant,
        text: 'GT_CURSOR_FIXTURE_RESPONSE',
        atUnixMs: 1_781_312_171_000,
        redacted: false,
        pendingToolCalls: [],
      },
    ],
    lastActivityUnixMs: 1_781_312_171_000,
    position: { row: 0, col: 0, rowSpan: 1, colSpan: 1 },
    hasVideoTrack: false,
    remoteAppId: 'cursor',
    availableTargets: [
      {
        targetId: 'fixture-cursor-chat-1',
        label: 'Cursor chat 1',
        subtitle: 'Cursor',
        selected: true,
        threadId: 'fixture-cursor-chat-1',
        threadLabel: 'Cursor chat 1',
        targetKind: 'thread',
        lastActivityUnixMs: 1_781_312_171_000,
        isActive: true,
      },
      {
        targetId: 'fixture-cursor-chat-2',
        label: 'Cursor chat 2',
        subtitle: 'Cursor',
        selected: false,
        threadId: 'fixture-cursor-chat-2',
        threadLabel: 'Cursor chat 2',
        targetKind: 'thread',
        lastActivityUnixMs: 1_781_312_160_000,
      },
    ],
  };
}

function cliSnapshot(
  agentId: 'claude-code' | 'cursor-agent' | 'gemini-cli' | 'opencode' | 'codex-cli',
  label: string,
  adapterKind: AdapterKind,
  overrides: Partial<AgentStateSnapshot> = {},
): AgentStateSnapshot {
  return {
    agentId,
    agentLabel: label,
    adapterKind,
    status: AgentStatus.Idle,
    statusDetail: 'Ready',
    recentMessages: [],
    lastActivityUnixMs: 1_781_312_050_000,
    position: { row: 0, col: 0, rowSpan: 1, colSpan: 1 },
    hasVideoTrack: false,
    remoteAppId: agentId,
    availableTargets: [
      {
        targetId: `fixture-${agentId}-session`,
        label: `${label} session`,
        subtitle: 'Ready',
        selected: false,
        threadId: `fixture-${agentId}-session`,
        threadLabel: `${label} session`,
        targetKind: 'thread',
        lastActivityUnixMs: 1_781_312_050_000,
      },
    ],
    ...overrides,
  };
}

function runningCliSnapshot(
  agentId: 'claude-code' | 'cursor-agent' | 'gemini-cli' | 'opencode' | 'codex-cli',
  label: string,
  adapterKind: AdapterKind,
  outputText: string,
  overrides: Partial<AgentStateSnapshot> = {},
): AgentStateSnapshot {
  return cliSnapshot(agentId, label, adapterKind, {
    status: AgentStatus.Working,
    statusDetail: 'Working',
    recentMessages: [
      {
        messageId: `${agentId}-running-user`,
        role: ChatRole.User,
        text: 'Review the current diff and suggest one next fix.',
        atUnixMs: 1_781_312_180_000,
        redacted: false,
        pendingToolCalls: [],
      },
      {
        messageId: `${agentId}-running-output`,
        role: ChatRole.Assistant,
        text: outputText,
        atUnixMs: 1_781_312_181_000,
        redacted: false,
        pendingToolCalls: [],
      },
    ],
    ...overrides,
  });
}

function openCodeThreadTargets(): AgentStateSnapshot['availableTargets'] {
  return [
    {
      targetId: 'fixture-opencode-thread-glass-tunnel-1',
      label: 'glasstunnel',
      subtitle: '~/Documents/GitHub2/glasstunnel',
      selected: true,
      projectId: '/Users/developer/Documents/GitHub2/glasstunnel',
      projectLabel: 'glasstunnel',
      projectPath: '/Users/developer/Documents/GitHub2/glasstunnel',
      threadId: 'fixture-opencode-thread-glass-tunnel-1',
      threadLabel: 'Glass Tunnel 1',
      targetKind: 'thread',
      lastActivityUnixMs: 1_781_312_180_000,
      isActive: true,
    },
    {
      targetId: 'fixture-opencode-thread-glass-tunnel-2',
      label: 'glasstunnel',
      subtitle: '~/Documents/GitHub2/glasstunnel',
      selected: false,
      projectId: '/Users/developer/Documents/GitHub2/glasstunnel',
      projectLabel: 'glasstunnel',
      projectPath: '/Users/developer/Documents/GitHub2/glasstunnel',
      threadId: 'fixture-opencode-thread-glass-tunnel-2',
      threadLabel: 'Glass Tunnel 2',
      targetKind: 'thread',
      lastActivityUnixMs: 1_781_312_120_000,
    },
  ];
}

function terminalRunningSnapshot(): AgentStateSnapshot {
  return {
    agentId: 'terminal',
    agentLabel: 'Terminal',
    adapterKind: AdapterKind.Terminal,
    status: AgentStatus.Working,
    statusDetail: 'running command',
    recentMessages: [
      {
        messageId: 'fixture-terminal-command',
        role: ChatRole.User,
        text: "printf 'GT_TERMINAL_STREAM\\n'; sleep 20",
        atUnixMs: 1_781_312_160_000,
        redacted: false,
        pendingToolCalls: [],
      },
      {
        messageId: 'fixture-terminal-output',
        role: ChatRole.Assistant,
        text: 'GT_TERMINAL_STREAM',
        atUnixMs: 1_781_312_161_000,
        redacted: false,
        pendingToolCalls: [],
      },
      {
        messageId: 'fixture-terminal-interrupt',
        role: ChatRole.System,
        text: 'interrupt sent',
        atUnixMs: 1_781_312_162_000,
        redacted: false,
        pendingToolCalls: [],
      },
    ],
    lastActivityUnixMs: 1_781_312_162_000,
    position: { row: 0, col: 0, rowSpan: 1, colSpan: 1 },
    hasVideoTrack: false,
    remoteAppId: 'terminal',
    availableTargets: [
      {
        targetId: 'terminal-session:glasstunnel-terminal',
        label: 'Default Terminal',
        subtitle: 'Current session',
        selected: true,
        threadId: 'terminal-session:glasstunnel-terminal',
        threadLabel: 'Default Terminal',
        targetKind: 'session',
        isActive: true,
        supportsNewThread: true,
      },
      {
        targetId: 'terminal-session:glasstunnel-terminal-two',
        label: 'Terminal 2',
        subtitle: 'Switch session',
        selected: false,
        threadId: 'terminal-session:glasstunnel-terminal-two',
        threadLabel: 'Terminal 2',
        targetKind: 'session',
        isActive: false,
        supportsNewThread: true,
      },
      {
        targetId: 'terminal-session:glasstunnel-terminal-three',
        label: 'Terminal 3',
        subtitle: 'Switch session',
        selected: false,
        threadId: 'terminal-session:glasstunnel-terminal-three',
        threadLabel: 'Terminal 3',
        targetKind: 'session',
        isActive: false,
        supportsNewThread: true,
      },
      {
        targetId: 'terminal-session:glasstunnel-terminal-four',
        label: 'Terminal 4',
        subtitle: 'Switch session',
        selected: false,
        threadId: 'terminal-session:glasstunnel-terminal-four',
        threadLabel: 'Terminal 4',
        targetKind: 'session',
        isActive: false,
        supportsNewThread: true,
      },
      {
        targetId: 'terminal-session:glasstunnel-build-shell',
        label: 'Build shell',
        subtitle: 'Switch session',
        selected: false,
        threadId: 'terminal-session:glasstunnel-build-shell',
        threadLabel: 'Build shell',
        targetKind: 'session',
        isActive: false,
        supportsNewThread: true,
      },
    ],
  };
}
