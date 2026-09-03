import { describe, expect, it } from 'vitest';
import { AdapterKind, AgentStatus, type AgentStateSnapshot, type RemoteApp } from '@glasstunnel/protocol';
import {
  appFiltersForAvailableApps,
  appReady,
  appStatusDotClass,
  buildProjectGroups,
  directCliStartTimedOut,
  focusedChatHeading,
  projectEmptyStateCopy,
  projectEmptyStateTitle,
  remoteAppActionTimedOut,
  terminalSessionActionCopy,
  remoteAppStartState,
  REMOTE_APP_ACTION_TIMEOUT_MS,
  shouldRequestTargetSelection,
  shouldShowStartRemoteAppPanel,
  shouldShowCommandTargetSwitcher,
  shouldResetAppFilter,
  startRemoteAppCopy,
  workspaceInitialAppIdFromSearch,
  workspaceConnectionNotice,
  workspaceStateCopy,
} from './AgentCarousel';

describe('AgentCarousel project grouping', () => {
  it('shows switcher filters only for apps published by this Mac', () => {
    const filters = appFiltersForAvailableApps(
      new Map([
        ['screen', directApp('screen')],
        ['codex', codexApp()],
        [
          'cursor',
          {
            ...codexApp(),
            remoteAppId: 'cursor',
            displayName: 'Cursor',
            agentId: 'cursor',
            available: false,
            status: AgentStatus.Disconnected,
            statusDetail: 'Open Cursor on this Mac',
          },
        ],
      ]),
    );

    expect(filters.map((filter) => filter.id)).toEqual(['all', 'screen', 'codex', 'cursor']);
    expect(filters.map((filter) => filter.id)).not.toContain('opencode');
    expect(filters.map((filter) => filter.id)).not.toContain('claude-code');
    expect(filters.map((filter) => filter.id)).not.toContain('gemini-cli');
  });

  it('hides the redundant all filter when only one project app is published', () => {
    const filters = appFiltersForAvailableApps(
      new Map([
        ['screen', directApp('screen')],
        ['codex', codexApp()],
        ['terminal', directApp('terminal')],
      ]),
    );

    expect(filters.map((filter) => filter.id)).toEqual(['screen', 'codex', 'terminal']);
  });

  it('keeps the all filter when multiple project apps are published', () => {
    const filters = appFiltersForAvailableApps(
      new Map([
        ['screen', directApp('screen')],
        ['codex', codexApp()],
        [
          'cursor',
          {
            ...codexApp(),
            remoteAppId: 'cursor',
            displayName: 'Cursor',
            agentId: 'cursor',
            available: true,
          },
        ],
      ]),
    );

    expect(filters.map((filter) => filter.id)).toEqual(['all', 'screen', 'codex', 'cursor']);
  });

  it('shows offline app switcher dots when the Mac is offline', () => {
    expect(appStatusDotClass(codexApp(), true, false)).toBe('bg-err');
  });

  it('does not create project or chat groups for direct features', () => {
    expect(buildProjectGroups(directApp('screen'))).toEqual([]);
    expect(buildProjectGroups(directApp('terminal'), snapshot())).toEqual([]);
    expect(buildProjectGroups(cliApp('codex-cli'), snapshot())).toEqual([]);
  });

  it('does not treat a stopped Terminal as ready just because a shell exists', () => {
    expect(appReady(directApp('terminal'))).toBe(true);
    expect(appReady({ ...directApp('terminal'), enabled: false, statusDetail: 'Stopped' })).toBe(false);
  });

  it('supports workspace app deep links', () => {
    expect(workspaceInitialAppIdFromSearch('?app=terminal')).toBe('terminal');
    expect(workspaceInitialAppIdFromSearch('?app=Screen')).toBe('screen');
    expect(workspaceInitialAppIdFromSearch('?app=codex')).toBe('codex');
    expect(workspaceInitialAppIdFromSearch('?app=cursor')).toBe('cursor');
    expect(workspaceInitialAppIdFromSearch('?app=codex-cli')).toBe('codex-cli');
    expect(workspaceInitialAppIdFromSearch('?app=cursor-agent')).toBe('cursor-agent');
    expect(workspaceInitialAppIdFromSearch('?app=claude-code')).toBe('claude-code');
    expect(workspaceInitialAppIdFromSearch('?app=gemini-cli')).toBe('gemini-cli');
    expect(workspaceInitialAppIdFromSearch('?app=opencode')).toBe('opencode');
    expect(workspaceInitialAppIdFromSearch('?app=all')).toBeNull();
    expect(workspaceInitialAppIdFromSearch('?app=unknown')).toBeNull();
  });

  it('preserves a workspace app deep link while remote apps are loading', () => {
    expect(shouldResetAppFilter('terminal', 0, new Map())).toBe(false);
    expect(shouldResetAppFilter('terminal', 1, new Map([['terminal', directApp('terminal')]]))).toBe(false);
    expect(shouldResetAppFilter('codex-cli', 1, new Map([['codex-cli', cliApp('codex-cli')]]))).toBe(false);
    expect(shouldResetAppFilter('cursor-agent', 1, new Map([['cursor-agent', cliApp('cursor-agent')]]))).toBe(false);
    expect(shouldResetAppFilter('cursor', 0, new Map())).toBe(false);
    expect(shouldResetAppFilter('cursor', 1, new Map([['cursor', cursorApp()]]))).toBe(false);
    expect(shouldResetAppFilter('terminal', 1, new Map([['codex', codexApp()]]))).toBe(true);
  });

  it('keeps project threads and standalone chats in separate groups', () => {
    const groups = buildProjectGroups(codexApp(), {
      ...snapshot(),
      availableTargets: [
        {
          targetId: '/tmp/project-thread.jsonl',
          label: 'glasstunnel',
          subtitle: '~/Documents/GitHub2/glasstunnel',
          selected: true,
          projectId: '/Users/developer/Documents/GitHub2/glasstunnel',
          projectLabel: 'glasstunnel',
          projectPath: '/Users/developer/Documents/GitHub2/glasstunnel',
          threadId: '/tmp/project-thread.jsonl',
          threadLabel: 'Glasstunnel 1',
          targetKind: 'thread',
          lastActivityUnixMs: 1000,
          isActive: true,
        },
        {
          targetId: '/tmp/standalone-chat.jsonl',
          label: 'Loose chat',
          subtitle: 'Standalone chat',
          selected: false,
          threadId: '/tmp/standalone-chat.jsonl',
          threadLabel: 'Loose chat',
          targetKind: 'thread',
          lastActivityUnixMs: 900,
        },
      ],
    });

    expect(groups).toHaveLength(2);
    expect(groups[0]).toMatchObject({
      kind: 'project',
      label: 'glasstunnel',
    });
    expect(groups[0].threads[0].threadLabel).toBe('Glasstunnel 1');
    expect(groups[0].threads[0].label).toBe('glasstunnel');
    expect(groups[1]).toMatchObject({
      kind: 'chat',
      label: 'Loose chat',
      path: 'Standalone chat',
    });
  });

  it('does not collapse a project thread name into the project folder label', () => {
    const groups = buildProjectGroups(codexApp(), {
      ...snapshot(),
      availableTargets: [
        {
          targetId: '/tmp/project-thread.jsonl',
          label: 'Glasstunnel 1',
          subtitle: '~/Documents/GitHub2/glasstunnel',
          selected: true,
          projectId: '/Users/developer/Documents/GitHub2/glasstunnel',
          projectLabel: 'glasstunnel',
          projectPath: '/Users/developer/Documents/GitHub2/glasstunnel',
          threadId: '/tmp/project-thread.jsonl',
          threadLabel: 'Glasstunnel 1',
          targetKind: 'thread',
          lastActivityUnixMs: 1000,
          isActive: true,
        },
      ],
    });

    expect(groups).toHaveLength(1);
    expect(groups[0].label).toBe('glasstunnel');
    expect(groups[0].threads[0].label).toBe('Glasstunnel 1');
    expect(groups[0].threads[0].threadLabel).toBe('Glasstunnel 1');
  });

  it('keeps generated Cursor fallback labels as standalone chats, not projects', () => {
    const groups = buildProjectGroups(cursorApp(), {
      ...snapshot(),
      agentId: 'cursor',
      agentLabel: 'Cursor',
      availableTargets: [
        {
          targetId: 'cursor-chat-1',
          label: 'Cursor chat 1',
          subtitle: 'Cursor',
          selected: true,
          threadId: 'cursor-chat-1',
          threadLabel: 'Cursor chat 1',
          targetKind: 'thread',
          lastActivityUnixMs: 2000,
          isActive: true,
        },
        {
          targetId: 'cursor-chat-2',
          label: 'Cursor chat 2',
          subtitle: 'Cursor',
          selected: false,
          threadId: 'cursor-chat-2',
          threadLabel: 'Cursor chat 2',
          targetKind: 'thread',
          lastActivityUnixMs: 1000,
        },
      ],
    });

    expect(groups).toHaveLength(2);
    expect(groups.map((group) => group.kind)).toEqual(['chat', 'chat']);
    expect(groups.map((group) => group.label)).toEqual(['Cursor chat 1', 'Cursor chat 2']);
    expect(groups.map((group) => group.path)).toEqual(['Cursor', 'Cursor']);
    expect(groups.flatMap((group) => group.threads.map((thread) => thread.projectLabel ?? null))).toEqual([null, null]);
  });

  it('does not invent a chat row for a project-only Codex target', () => {
    const groups = buildProjectGroups(codexApp(), {
      ...snapshot(),
      availableTargets: [
        {
          targetId: '/Users/developer/Documents/GitHub2/glasstunnel',
          label: 'glasstunnel',
          subtitle: '~/Documents/GitHub2/glasstunnel',
          selected: true,
          projectId: '/Users/developer/Documents/GitHub2/glasstunnel',
          projectLabel: 'glasstunnel',
          projectPath: '/Users/developer/Documents/GitHub2/glasstunnel',
          threadId: '/Users/developer/Documents/GitHub2/glasstunnel',
          targetKind: 'project',
          isActive: true,
        },
      ],
    });

    expect(groups).toHaveLength(1);
    expect(groups[0]).toMatchObject({
      kind: 'project',
      label: 'glasstunnel',
      threads: [],
      selected: true,
    });
    expect(groups[0].directTarget?.targetKind).toBe('project');
  });

  it('does not render unavailable apps with no targets as fake chats', () => {
    const groups = buildProjectGroups(
      {
        ...codexApp(),
        remoteAppId: 'cursor',
        displayName: 'Cursor',
        agentId: 'cursor',
        available: false,
        status: AgentStatus.Disconnected,
        statusDetail: 'Open Cursor on this Mac',
      },
      {
        ...snapshot(),
        agentId: 'cursor',
        agentLabel: 'Cursor',
        status: AgentStatus.Disconnected,
        statusDetail: 'Open Cursor on this Mac',
        availableTargets: [],
      },
    );

    expect(groups).toEqual([]);
  });
});

describe('AgentCarousel primary copy', () => {
  it('keeps empty states short and free of internal transport wording', () => {
    const copies = [
      workspaceStateCopy('connecting'),
      workspaceStateCopy('syncing-apps'),
      projectEmptyStateCopy({ searchQuery: '', directFeature: false }),
      startRemoteAppCopy({
        appName: 'Codex CLI',
        available: true,
        offline: false,
        pending: false,
        fallbackStatusDetail: '',
      }),
    ];

    for (const copy of copies) {
      expect(copy.length).toBeLessThanOrEqual(72);
      expect(copy).not.toMatch(/relay|publishes|CLI tools|visible window/i);
    }
  });

  it('uses accurate empty state titles for search, workspace, and direct features', () => {
    expect(projectEmptyStateTitle({ searchQuery: '', directFeatureName: undefined })).toBe('No projects yet');
    expect(projectEmptyStateCopy({ searchQuery: '', directFeature: false })).toBe(
      'Open a coding app on your Mac.',
    );

    expect(projectEmptyStateTitle({ searchQuery: 'cursor', directFeatureName: undefined })).toBe('No results');
    expect(projectEmptyStateCopy({ searchQuery: 'cursor', directFeature: false })).toBe(
      'Try another project, chat, or app.',
    );

    expect(projectEmptyStateTitle({ searchQuery: '', directFeatureName: 'Mac Screen' })).toBe(
      'Mac Screen opens directly',
    );
    expect(projectEmptyStateCopy({ searchQuery: '', directFeature: true })).toBe(
      'Choose it from the app switcher.',
    );
  });

  it('surfaces Mac launch failures as a retryable error state', () => {
    expect(
      remoteAppStartState({
        appName: 'Cursor',
        available: false,
        status: AgentStatus.Error,
        offline: false,
        pending: false,
        fallbackStatusDetail: 'Open failed',
      }),
    ).toEqual({
      title: 'Cursor could not open',
      copy: 'Try again or open it on the Mac.',
      detail: 'Open failed',
      action: 'Retry',
      tone: 'error',
    });
  });

  it('uses open-terminal copy when Terminal exists but is stopped', () => {
    expect(
      remoteAppStartState({
        appName: 'Terminal',
        available: true,
        status: AgentStatus.Idle,
        offline: false,
        pending: false,
        fallbackStatusDetail: 'Stopped',
      }),
    ).toEqual({
      title: 'Terminal is ready',
      copy: 'Open Terminal on this Mac.',
      action: 'Open Terminal',
      tone: 'neutral',
    });
  });

  it('shows the Open Terminal action until a live Terminal snapshot arrives', () => {
    const terminal = directApp('terminal');

    expect(shouldShowStartRemoteAppPanel(terminal)).toBe(true);
    expect(shouldShowStartRemoteAppPanel(terminal, {
      ...snapshot(),
      agentId: 'terminal',
      agentLabel: 'Terminal',
      adapterKind: AdapterKind.Terminal,
    })).toBe(false);
  });

  it('shows the Open Terminal action again when Terminal has a stale offline snapshot', () => {
    const terminal = {
      ...directApp('terminal'),
      status: AgentStatus.Disconnected,
      statusDetail: 'Offline',
    };

    expect(shouldShowStartRemoteAppPanel(terminal, {
      ...snapshot(),
      agentId: 'terminal',
      agentLabel: 'Terminal',
      adapterKind: AdapterKind.Terminal,
      status: AgentStatus.Disconnected,
      statusDetail: 'Offline',
    })).toBe(true);
  });

  it('shows a Start action again when a direct CLI has a stale stopped snapshot', () => {
    const codexCli = {
      ...cliApp('codex-cli'),
      status: AgentStatus.Disconnected,
      statusDetail: 'process exited (0)',
    };

    expect(shouldShowStartRemoteAppPanel(codexCli, {
      ...snapshot(),
      agentId: 'codex-cli',
      agentLabel: 'Codex CLI',
      adapterKind: AdapterKind.CodexCli,
      status: AgentStatus.Disconnected,
      statusDetail: 'process exited (0)',
    })).toBe(true);
    expect(appReady(codexCli)).toBe(false);
  });

  it('does not treat an exited direct CLI process as ready', () => {
    const codexCli = {
      ...cliApp('codex-cli'),
      status: AgentStatus.Done,
      statusDetail: 'process exited (0)',
    };

    expect(shouldShowStartRemoteAppPanel(codexCli, {
      ...snapshot(),
      agentId: 'codex-cli',
      agentLabel: 'Codex CLI',
      adapterKind: AdapterKind.CodexCli,
      status: AgentStatus.Done,
      statusDetail: 'process exited (0)',
    })).toBe(true);
    expect(appReady(codexCli)).toBe(false);
  });

  it('uses stopped copy for an exited direct CLI process', () => {
    expect(
      remoteAppStartState({
        appName: 'Codex CLI',
        available: true,
        status: AgentStatus.Done,
        offline: false,
        pending: false,
        fallbackStatusDetail: 'process exited (0)',
      }),
    ).toEqual({
      title: 'Codex CLI stopped',
      copy: 'Start Codex CLI on this Mac.',
      action: 'Start',
      tone: 'neutral',
    });
  });

  it('turns stale direct CLI starting snapshots back into a retryable state', () => {
    const startedAt = 10_000;
    const codexCli = {
      ...cliApp('codex-cli'),
      status: AgentStatus.Working,
      statusDetail: 'Starting',
    };
    const codexSnapshot = {
      ...snapshot(),
      agentId: 'codex-cli',
      agentLabel: 'Codex CLI',
      adapterKind: AdapterKind.CodexCli,
      status: AgentStatus.Working,
      statusDetail: 'Starting',
      lastActivityUnixMs: startedAt,
    };

    expect(directCliStartTimedOut(codexCli, codexSnapshot, startedAt + REMOTE_APP_ACTION_TIMEOUT_MS - 1)).toBe(false);
    expect(directCliStartTimedOut(codexCli, codexSnapshot, startedAt + REMOTE_APP_ACTION_TIMEOUT_MS)).toBe(true);
    expect(
      remoteAppStartState({
        appName: 'Codex CLI',
        available: true,
        status: AgentStatus.Working,
        offline: false,
        pending: false,
        timedOut: true,
        fallbackStatusDetail: 'Starting',
      }),
    ).toEqual({
      title: 'Codex CLI did not respond',
      copy: 'Try again or open it on the Mac.',
      detail: 'Starting',
      action: 'Retry',
      tone: 'error',
    });
  });

  it('applies stale direct CLI starting timeout to non-Codex CLI apps only', () => {
    const now = 40_000;
    const staleStartingSnapshot = {
      ...snapshot(),
      status: AgentStatus.Working,
      statusDetail: 'Starting',
      lastActivityUnixMs: now - REMOTE_APP_ACTION_TIMEOUT_MS,
    };

    expect(directCliStartTimedOut({
      ...cliApp('opencode'),
      status: AgentStatus.Working,
      statusDetail: 'Starting',
    }, staleStartingSnapshot, now)).toBe(true);
    expect(directCliStartTimedOut({
      ...cliApp('gemini-cli'),
      status: AgentStatus.Working,
      statusDetail: 'Starting',
    }, staleStartingSnapshot, now)).toBe(true);
    expect(directCliStartTimedOut({
      ...directApp('terminal'),
      status: AgentStatus.Working,
      statusDetail: 'Starting',
    }, staleStartingSnapshot, now)).toBe(false);
  });

  it('keeps pending app actions bounded so opening does not last forever', () => {
    const pending = { action: 'launch' as const, atUnixMs: 10_000 };

    expect(remoteAppActionTimedOut(pending, 10_000 + REMOTE_APP_ACTION_TIMEOUT_MS - 1)).toBe(false);
    expect(remoteAppActionTimedOut(pending, 10_000 + REMOTE_APP_ACTION_TIMEOUT_MS)).toBe(true);

    expect(
      remoteAppStartState({
        appName: 'Cursor',
        available: false,
        status: AgentStatus.Disconnected,
        offline: false,
        pending: true,
        timedOut: false,
        fallbackStatusDetail: 'Opening Cursor',
      }),
    ).toMatchObject({
      title: 'Opening Cursor',
      copy: 'Waiting for your Mac.',
      action: 'Retry',
      tone: 'neutral',
    });

    expect(
      remoteAppStartState({
        appName: 'Cursor',
        available: false,
        status: AgentStatus.Disconnected,
        offline: false,
        pending: false,
        timedOut: true,
        fallbackStatusDetail: 'Opening Cursor',
      }),
    ).toEqual({
      title: 'Cursor did not respond',
      copy: 'Try again or open it on the Mac.',
      detail: 'Opening Cursor',
      action: 'Retry',
      tone: 'error',
    });
  });

  it('uses clear Terminal new-session pending copy', () => {
    expect(terminalSessionActionCopy('newSession')).toBe('New');
    expect(terminalSessionActionCopy('newSession', { action: 'newSession', atUnixMs: 10_000 })).toBe('Starting');
    expect(terminalSessionActionCopy('closeSession')).toBe('Close');
    expect(terminalSessionActionCopy('closeSession', { action: 'closeSession', atUnixMs: 10_000 })).toBe('Closing');
    expect(terminalSessionActionCopy('newSession', { action: 'closeSession', atUnixMs: 10_000 })).toBe('New');
  });

  it('shows focused target switching for Terminal, OpenCode, Cursor, Codex, and Claude', () => {
    expect(shouldShowCommandTargetSwitcher(directApp('terminal'))).toBe(true);
    expect(shouldShowCommandTargetSwitcher(cliApp('opencode'))).toBe(true);
    expect(shouldShowCommandTargetSwitcher({ ...codexApp(), remoteAppId: 'cursor', agentId: 'cursor' })).toBe(true);
    expect(shouldShowCommandTargetSwitcher(codexApp())).toBe(true);
    expect(
      shouldShowCommandTargetSwitcher({
        ...codexApp(),
        remoteAppId: 'claude-desktop',
        agentId: 'claude-desktop',
        adapterKind: AdapterKind.ClaudeDesktop,
      }),
    ).toBe(true);
    expect(shouldShowCommandTargetSwitcher(cliApp('claude-code'))).toBe(true);
    expect(shouldShowCommandTargetSwitcher(cliApp('codex-cli'))).toBe(false);
    expect(shouldShowCommandTargetSwitcher(cliApp('cursor-agent'))).toBe(false);
    expect(shouldShowCommandTargetSwitcher(cliApp('gemini-cli'))).toBe(false);
    expect(shouldShowCommandTargetSwitcher(directApp('screen'))).toBe(false);
  });

  it('retries a selected Codex or Claude desktop target until the app confirms it is active', () => {
    expect(shouldRequestTargetSelection(codexApp(), { selected: true, isActive: false })).toBe(true);
    expect(shouldRequestTargetSelection(codexApp(), { selected: true, isActive: true })).toBe(false);
    expect(shouldRequestTargetSelection(codexApp(), { selected: false, isActive: false })).toBe(true);
    expect(
      shouldRequestTargetSelection({ ...codexApp(), remoteAppId: 'claude-desktop' }, { selected: true, isActive: false }),
    ).toBe(true);
    expect(
      shouldRequestTargetSelection({ ...codexApp(), remoteAppId: 'claude-desktop' }, { selected: true, isActive: true }),
    ).toBe(false);
    expect(shouldRequestTargetSelection(cliApp('claude-code'), { selected: true, isActive: false })).toBe(false);
    expect(shouldRequestTargetSelection(cursorApp(), { selected: true, isActive: false })).toBe(false);
  });

  it('shows cached workspace connection issues without hiding projects', () => {
    expect(
      workspaceConnectionNotice({
        hostOnline: false,
        connectionError: 'Mac offline. Open Glasstunnel on the Mac, then retry.',
        hasContent: true,
      }),
    ).toEqual({
      title: 'Mac offline',
      copy: 'Projects and chats stay visible.',
      detail: 'Mac offline. Open Glasstunnel on the Mac, then retry.',
      action: 'Retry',
      tone: 'error',
    });

    expect(
      workspaceConnectionNotice({
        hostOnline: null,
        connectionError: 'Connection lost. Reconnecting.',
        hasContent: true,
      }),
    ).toEqual({
      title: 'Reconnecting',
      copy: 'Projects and chats stay visible.',
      detail: 'Connection lost. Reconnecting.',
      action: 'Retry',
      tone: 'warning',
    });
  });

  it('does not show a cached workspace banner before content exists', () => {
    expect(
      workspaceConnectionNotice({
        hostOnline: false,
        connectionError: 'Mac offline. Open Glasstunnel on the Mac, then retry.',
        hasContent: false,
      }),
    ).toBeNull();
  });
});

function directApp(remoteAppId: 'screen' | 'terminal'): RemoteApp {
  return {
    remoteAppId,
    displayName: remoteAppId === 'screen' ? 'Mac Screen' : 'Terminal',
    adapterKind: AdapterKind.Mirror,
    agentId: remoteAppId,
    enabled: true,
    available: true,
    status: AgentStatus.Idle,
    statusDetail: 'Ready',
    windowTitle: '',
    applicationBundleId: '',
    hasVideo: remoteAppId === 'screen',
  };
}

function cliApp(remoteAppId: 'codex-cli' | 'cursor-agent' | 'claude-code' | 'gemini-cli' | 'opencode'): RemoteApp {
  const adapterKind =
    remoteAppId === 'codex-cli'
      ? AdapterKind.CodexCli
      : remoteAppId === 'cursor-agent'
        ? AdapterKind.CursorAgent
      : remoteAppId === 'claude-code'
        ? AdapterKind.ClaudeCode
        : remoteAppId === 'gemini-cli'
          ? AdapterKind.GeminiCli
          : AdapterKind.OpenCode;
  const displayName =
    remoteAppId === 'codex-cli'
      ? 'Codex CLI'
      : remoteAppId === 'cursor-agent'
        ? 'Cursor Agent'
      : remoteAppId === 'claude-code'
        ? 'Claude Code'
        : remoteAppId === 'gemini-cli'
          ? 'Gemini CLI'
          : 'OpenCode';
  return {
    remoteAppId,
    displayName,
    adapterKind,
    agentId: remoteAppId,
    enabled: true,
    available: true,
    status: AgentStatus.Idle,
    statusDetail: 'Ready',
    windowTitle: '',
    applicationBundleId: '',
    hasVideo: false,
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

function cursorApp(): RemoteApp {
  return {
    remoteAppId: 'cursor',
    displayName: 'Cursor',
    adapterKind: AdapterKind.Cursor,
    agentId: 'cursor',
    enabled: true,
    available: true,
    status: AgentStatus.Idle,
    statusDetail: 'Ready',
    windowTitle: 'Cursor',
    applicationBundleId: 'com.todesktop.230313mzl4w4u92',
    hasVideo: false,
  };
}

function snapshot(): AgentStateSnapshot {
  return {
    agentId: 'codex',
    agentLabel: 'Codex',
    adapterKind: AdapterKind.Mirror,
    status: AgentStatus.Idle,
    statusDetail: 'Ready',
    recentMessages: [],
    lastActivityUnixMs: 1000,
    position: { row: 0, col: 0, rowSpan: 1, colSpan: 1 },
    hasVideoTrack: false,
  };
}

describe('focusedChatHeading', () => {
  it('names the session first and the project second, never the same thing twice', () => {
    expect(
      focusedChatHeading({
        agentLabel: 'glasstunnel 1',
        groupLabel: 'how-are-you-25115d',
        groupPath: '/Users/dev/Workspace/glasstunnel/.claude/worktrees/how-are-you-25115d',
        displayName: 'Claude',
        statusDetail: 'Response ready',
      }),
    ).toEqual({ title: 'glasstunnel 1', subtitle: 'how-are-you-25115d' });
    expect(
      focusedChatHeading({
        groupLabel: 'glasstunnel',
        groupPath: '/Users/dev/Workspace/glasstunnel',
        displayName: 'Codex',
      }),
    ).toEqual({ title: 'glasstunnel', subtitle: '/Users/dev/Workspace/glasstunnel' });
  });

  it('prefers a thread label and the project label of its target', () => {
    expect(
      focusedChatHeading({
        threadLabel: 'Settings screen',
        targetLabel: 'Settings screen',
        projectLabel: 'glasstunnel',
        projectPath: '/Users/dev/Documents/GitHub2/glasstunnel',
        agentLabel: 'Settings screen',
        displayName: 'Claude',
      }),
    ).toEqual({ title: 'Settings screen', subtitle: 'glasstunnel' });
  });

  it('keeps the Terminal session name as the subtitle', () => {
    expect(
      focusedChatHeading({
        agentLabel: 'Terminal',
        terminalSessionLabel: 'build',
        groupLabel: 'Terminal',
        displayName: 'Terminal',
      }),
    ).toEqual({ title: 'Terminal', subtitle: 'build' });
  });
});
