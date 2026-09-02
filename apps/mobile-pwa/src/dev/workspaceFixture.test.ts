import { describe, expect, it } from 'vitest';
import { AgentStatus, type RemoteApp } from '@glasstunnel/protocol';
import { appFiltersForAvailableApps } from '../agents/AgentCarousel';
import { workspaceFixtureInitialAppId, workspaceFixtureState } from './workspaceFixture';

describe('workspace mobile fixtures', () => {
  it('models a signed-in account with no Macs yet', () => {
    const state = workspaceFixtureState('hosts-empty');

    expect(state.route).toBe('hosts');
    expect(state.user?.email).toBe('fixture@glasstunnel.test');
    expect(state.availableHosts).toEqual([]);
    expect(state.pairedHost).toBeNull();
  });

  it('models signed-in host selection with online, offline, and preparing Macs', () => {
    const state = workspaceFixtureState('hosts-mixed');

    expect(state.route).toBe('hosts');
    expect(state.availableHosts?.map((host) => [host.label, host.online, host.trusted])).toEqual([
      ["Test Mac", true, true],
      ['MacBook Pro', false, true],
      ['Office Mac', true, false],
    ]);
    expect(typeof state.refreshHosts).toBe('function');
    expect(typeof state.chooseHost).toBe('function');
  });

  it('models a connected workspace with no synced projects or chats', () => {
    const state = workspaceFixtureState('workspace-empty');
    const filters = appFiltersForAvailableApps(appMap(state.remoteApps));

    expect(filters.map((filter) => filter.id)).toEqual(['screen', 'codex', 'terminal']);
    expect(state.agents).toEqual({});
  });

  it('models a one-project-app workspace without a redundant all filter', () => {
    const state = workspaceFixtureState('workspace-single-app');
    const filters = appFiltersForAvailableApps(appMap(state.remoteApps));

    expect(filters.map((filter) => filter.id)).toEqual(['screen', 'codex', 'terminal']);
    expect(Object.keys(state.agents ?? {})).toEqual(['codex']);
  });

  it('models a multi-project-app workspace with the all filter', () => {
    const state = workspaceFixtureState('workspace-multi-app');
    const filters = appFiltersForAvailableApps(appMap(state.remoteApps));

    expect(filters.map((filter) => filter.id)).toEqual(['all', 'screen', 'codex', 'cursor', 'terminal']);
    expect(Object.keys(state.agents ?? {})).toEqual(['codex', 'cursor']);
  });

  it('models a dense workspace with every supported app switcher item present', () => {
    const state = workspaceFixtureState('workspace-all-apps');
    const filters = appFiltersForAvailableApps(appMap(state.remoteApps));

    expect(filters.map((filter) => filter.id)).toEqual([
      'all',
      'screen',
      'codex',
      'claude-desktop',
      'claude-code',
      'cursor',
      'cursor-agent',
      'gemini-cli',
      'opencode',
      'codex-cli',
      'terminal',
    ]);
    expect(Object.keys(state.agents ?? {}).sort()).toEqual([
      'claude-code',
      'claude-desktop',
      'codex',
      'codex-cli',
      'cursor',
      'cursor-agent',
      'gemini-cli',
      'opencode',
    ]);
    expect(state.hostHello?.supportedAdapters).toEqual([
      'screen',
      'codex',
      'claude-desktop',
      'claude-code',
      'cursor',
      'cursor-agent',
      'gemini-cli',
      'opencode',
      'codex-cli',
      'terminal',
    ]);
  });

  it('models a stopped Codex CLI direct surface with stale output', () => {
    const state = workspaceFixtureState('workspace-codex-cli-stopped');
    const codexCli = state.remoteApps?.find((app) => app.remoteAppId === 'codex-cli');

    expect(codexCli?.enabled).toBe(true);
    expect(codexCli?.available).toBe(true);
    expect(codexCli?.status).toBe(AgentStatus.Done);
    expect(codexCli?.statusDetail).toBe('process exited (0)');
    expect(state.agents?.['codex-cli']?.status).toBe(AgentStatus.Done);
    expect(state.requestRemoteAppAction?.('codex-cli', 'start')).toBe(true);
  });

  it('models a stale starting Codex CLI direct surface', () => {
    const state = workspaceFixtureState('workspace-codex-cli-starting');
    const codexCli = state.remoteApps?.find((app) => app.remoteAppId === 'codex-cli');

    expect(codexCli?.enabled).toBe(true);
    expect(codexCli?.available).toBe(true);
    expect(codexCli?.status).toBe(AgentStatus.Working);
    expect(codexCli?.statusDetail).toBe('Starting');
    expect(state.agents?.['codex-cli']?.status).toBe(AgentStatus.Working);
    expect(state.agents?.['codex-cli']?.statusDetail).toBe('Starting');
    expect(state.agents?.['codex-cli']?.recentMessages.at(-1)?.text).toBe('Starting Codex CLI on this Mac.');
    expect(state.requestRemoteAppAction?.('codex-cli', 'start')).toBe(true);
  });

  it('models a running Codex CLI command surface', () => {
    const state = workspaceFixtureState('workspace-codex-cli-running');
    const codexCli = state.remoteApps?.find((app) => app.remoteAppId === 'codex-cli');
    const snapshot = state.agents?.['codex-cli'];

    expect(codexCli?.enabled).toBe(true);
    expect(codexCli?.available).toBe(true);
    expect(codexCli?.status).toBe(AgentStatus.Working);
    expect(codexCli?.statusDetail).toBe('Working');
    expect(snapshot?.status).toBe(AgentStatus.Working);
    expect(snapshot?.recentMessages.map((message) => message.text)).toEqual([
      'Review the current diff and suggest one next fix.',
      '>_ OpenAI Codex\nmodel: gpt-5.5 xhigh\n\nI found one focused next fix.',
    ]);
  });

  it('models a selected Codex chat that the desktop has not activated', () => {
    const state = workspaceFixtureState('workspace-codex-target-unverified');
    const selected = state.agents?.codex?.availableTargets?.find((target) => target.selected);

    expect(workspaceFixtureInitialAppId('workspace-codex-target-unverified')).toBe('codex');
    expect(state.agents?.codex?.agentLabel).toBe('Glasstunnel 1');
    expect(selected).toMatchObject({
      threadLabel: 'Glasstunnel 1',
      projectLabel: 'glasstunnel',
      selected: true,
      isActive: false,
    });
  });

  it("models Claude Code's workspace-trust dialog as a pending decision", () => {
    const state = workspaceFixtureState('workspace-claude-code-trust');
    const snapshot = state.agents?.['claude-code'];
    const app = state.remoteApps?.find((candidate) => candidate.remoteAppId === 'claude-code');

    expect(app?.enabled).toBe(true);
    expect(snapshot?.status).toBe(AgentStatus.WaitingInput);
    expect(snapshot?.statusDetail).toBe('Trust this folder?');
    expect(snapshot?.pendingInputRequest?.requestId).toBe('claude-code-trust-prompt');
    expect(snapshot?.pendingInputRequest?.questions[0]?.choices.map((choice) => choice.label)).toEqual([
      'Yes, I trust this folder',
      'No, exit',
    ]);
  });

  it('models running command surfaces for non-Codex CLI apps', () => {
    const cases = [
      ['workspace-opencode-running', 'opencode', 'OpenCode', 'provider/model: opencode/nemotron-3-ultra-free'],
      ['workspace-cursor-agent-running', 'cursor-agent', 'Cursor Agent', 'model: gpt-5.4-nano-none'],
      ['workspace-gemini-cli-running', 'gemini-cli', 'Gemini CLI', 'model: gemini-2.5-pro'],
      ['workspace-claude-code-running', 'claude-code', 'Claude Code', 'model: sonnet'],
    ] as const;

    for (const [fixtureId, appId, label, expectedOutput] of cases) {
      const state = workspaceFixtureState(fixtureId);
      const app = state.remoteApps?.find((candidate) => candidate.remoteAppId === appId);
      const snapshot = state.agents?.[appId];

      expect(app?.enabled).toBe(true);
      expect(app?.available).toBe(true);
      expect(app?.status).toBe(AgentStatus.Working);
      expect(app?.statusDetail).toBe('Working');
      expect(snapshot?.agentLabel).toBe(label);
      expect(snapshot?.status).toBe(AgentStatus.Working);
      expect(snapshot?.recentMessages[0]?.text).toBe('Review the current diff and suggest one next fix.');
      expect(snapshot?.recentMessages[1]?.text).toContain(expectedOutput);
    }
  });

  it('models OpenCode same-project sessions with distinct thread titles', () => {
    const state = workspaceFixtureState('workspace-opencode-running');
    const targets = state.agents?.opencode?.availableTargets;

    expect(targets?.map((target) => target.threadLabel)).toEqual(['Glass Tunnel 1', 'Glass Tunnel 2']);
    expect(targets?.map((target) => target.projectLabel)).toEqual(['glasstunnel', 'glasstunnel']);
    expect(targets?.map((target) => target.label)).toEqual(['glasstunnel', 'glasstunnel']);
    expect(targets?.map((target) => target.selected)).toEqual([true, false]);
  });

  it('models Cursor generated fallback labels as distinct chats', () => {
    const state = workspaceFixtureState('workspace-cursor-generated-labels');
    const cursor = state.remoteApps?.find((app) => app.remoteAppId === 'cursor');
    const snapshot = state.agents?.cursor;

    expect(cursor?.available).toBe(true);
    expect(snapshot?.availableTargets?.map((target) => target.label)).toEqual(['Cursor chat 1', 'Cursor chat 2']);
    expect(snapshot?.availableTargets?.map((target) => target.projectId ?? null)).toEqual([null, null]);
    expect(snapshot?.availableTargets?.map((target) => target.targetKind)).toEqual(['thread', 'thread']);
    expect(snapshot?.availableTargets?.map((target) => target.selected)).toEqual([true, false]);
  });

  it('models an offline cached workspace with visible projects and retry state', () => {
    const state = workspaceFixtureState('workspace-offline-cached');
    const filters = appFiltersForAvailableApps(appMap(state.remoteApps));

    expect(filters.map((filter) => filter.id)).toEqual(['screen', 'codex', 'terminal']);
    expect(Object.keys(state.agents ?? {})).toEqual(['codex']);
    expect(state.relayHostOnline).toBe(false);
    expect(state.error).toBe('Mac offline. Open Glasstunnel on the Mac, then retry.');
  });

  it('models an offline Mac Screen control panel fixture', () => {
    const state = workspaceFixtureState('workspace-screen-offline');
    const screen = state.remoteApps?.find((app) => app.remoteAppId === 'screen');

    expect(workspaceFixtureInitialAppId('workspace-screen-offline')).toBe('screen');
    expect(screen?.enabled).toBe(true);
    expect(screen?.hasVideo).toBe(true);
    expect(state.relayHostOnline).toBe(false);
    expect(state.relayScreenFrames).toEqual({});
    expect(state.videoStreams).toEqual({});
    expect(state.error).toBe('Mac offline. Open Glasstunnel on the Mac, then retry.');
  });

  it('models a stopping Mac Screen control panel fixture', () => {
    const state = workspaceFixtureState('workspace-screen-stopping');
    const screen = state.remoteApps?.find((app) => app.remoteAppId === 'screen');

    expect(workspaceFixtureInitialAppId('workspace-screen-stopping')).toBe('screen');
    expect(screen?.enabled).toBe(true);
    expect(screen?.status).toBe(AgentStatus.Working);
    expect(screen?.statusDetail).toBe('Stopping stream');
    expect(state.agents?.screen?.statusDetail).toBe('Stopping stream');
    expect(state.relayHostOnline).toBe(true);
    expect(state.relayScreenFrames).toEqual({});
    expect(state.videoStreams).toEqual({});
    expect(state.error).toBeNull();
    expect(state.requestRemoteAppAction?.('screen', 'start')).toBe(true);
  });

  it('models a running Terminal control panel fixture', () => {
    const state = workspaceFixtureState('workspace-terminal-running');
    const terminal = state.remoteApps?.find((app) => app.remoteAppId === 'terminal');

    expect(workspaceFixtureInitialAppId('workspace-terminal-running')).toBe('terminal');
    expect(terminal?.status).toBe(AgentStatus.Working);
    expect(terminal?.statusDetail).toBe('running command');
    expect(state.agents?.terminal?.status).toBe(AgentStatus.Working);
    expect(state.agents?.terminal?.statusDetail).toBe('running command');
    expect(state.agents?.terminal?.recentMessages.map((message) => message.text)).toEqual([
      "printf 'GT_TERMINAL_STREAM\\n'; sleep 20",
      'GT_TERMINAL_STREAM',
      'interrupt sent',
    ]);
    expect(state.agents?.terminal?.availableTargets?.map((target) => target.label)).toEqual([
      'Default Terminal',
      'Terminal 2',
      'Terminal 3',
      'Terminal 4',
      'Build shell',
    ]);
  });

  it('models a stopped Terminal launch fixture', () => {
    const state = workspaceFixtureState('workspace-terminal-stopped');
    const terminal = state.remoteApps?.find((app) => app.remoteAppId === 'terminal');

    expect(workspaceFixtureInitialAppId('workspace-terminal-stopped')).toBe('terminal');
    expect(terminal?.enabled).toBe(false);
    expect(terminal?.available).toBe(true);
    expect(terminal?.status).toBe(AgentStatus.Idle);
    expect(terminal?.statusDetail).toBe('Stopped');
    expect(state.agents?.terminal).toBeUndefined();
    expect(state.relayHostOnline).toBe(true);
    expect(state.requestRemoteAppAction?.('terminal', 'start')).toBe(true);
  });
});

function appMap(remoteApps: RemoteApp[] | undefined): Map<string, RemoteApp> {
  return new Map((remoteApps ?? []).map((app) => [app.remoteAppId, app]));
}
