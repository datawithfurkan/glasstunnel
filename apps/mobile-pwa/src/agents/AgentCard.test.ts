import { describe, expect, it } from 'vitest';
import { AdapterKind, AgentStatus, type RemoteApp } from '@glasstunnel/protocol';
import {
  agentInteractionUnavailable,
  commandTargetButtonState,
  commandTargetButtonDisplay,
  commandSurfaceInteractionUnavailable,
  cliControlNotice,
  commandSurfaceNotice,
  commandSurfacePromptPlaceholder,
  commandSurfaceSupportsAttachments,
  codexTargetInteractionUnavailable,
  cursorAgentControlNotice,
  cursorTargetInteractionUnavailable,
  isCommandSurfaceApp,
  isTerminalApp,
  runtimeControlsUnavailable,
  selectedTerminalSessionLabel,
  terminalControlNotice,
  terminalEmptyText,
  terminalLoadingText,
  terminalTargetButtonState,
  terminalStatusLabel,
  terminalSwitchingSession,
} from './AgentCard';

describe('AgentCard terminal copy', () => {
  it('makes clear that Terminal commands run on the linked Mac', () => {
    expect(terminalControlNotice()).toBe('Runs on your Mac. Review commands before running.');
  });

  it('uses prompt-oriented copy for CLI command surfaces', () => {
    const codexCli = remoteApp('codex-cli', AdapterKind.CodexCli, 'Codex CLI');
    expect(cliControlNotice()).toBe('Runs on your Mac. Review prompts before sending.');
    expect(commandSurfaceNotice(codexCli)).toBe('Runs on your Mac. Review prompts before sending.');
    expect(commandSurfacePromptPlaceholder(codexCli)).toBe('Send a prompt...');
  });

  it('keeps shell command copy for Terminal command surfaces', () => {
    const terminal = remoteApp('terminal', AdapterKind.Terminal, 'Terminal');
    expect(commandSurfaceNotice(terminal)).toBe('Runs on your Mac. Review commands before running.');
    expect(commandSurfacePromptPlaceholder(terminal)).toBe('Type a terminal command...');
  });

  it('keeps Cursor Agent ask-mode limits visible', () => {
    const cursorAgent = remoteApp('cursor-agent', AdapterKind.CursorAgent, 'Cursor Agent');
    expect(cursorAgentControlNotice()).toBe('Ask mode only. File edits are not enabled.');
    expect(commandSurfaceNotice(cursorAgent)).toBe('Ask mode only. File edits are not enabled.');
  });

  it('hides attachments for the ask-only Cursor Agent surface', () => {
    expect(commandSurfaceSupportsAttachments(remoteApp('cursor-agent', AdapterKind.CursorAgent, 'Cursor Agent'))).toBe(false);
    expect(commandSurfaceSupportsAttachments(remoteApp('codex-cli', AdapterKind.CodexCli, 'Codex CLI'))).toBe(true);
    expect(commandSurfaceSupportsAttachments(remoteApp('terminal', AdapterKind.Terminal, 'Terminal'))).toBe(true);
    expect(commandSurfaceSupportsAttachments(remoteApp('cursor', AdapterKind.Cursor, 'Cursor'))).toBe(true);
  });

  it('classifies only Terminal and CLI-backed apps as command surfaces', () => {
    expect(isTerminalApp(remoteApp('terminal', AdapterKind.Terminal, 'Terminal'))).toBe(true);
    expect(isCommandSurfaceApp(remoteApp('terminal', AdapterKind.Terminal, 'Terminal'))).toBe(true);
    expect(isCommandSurfaceApp(remoteApp('codex-cli', AdapterKind.CodexCli, 'Codex CLI'))).toBe(true);
    expect(isCommandSurfaceApp(remoteApp('cursor-agent', AdapterKind.CursorAgent, 'Cursor Agent'))).toBe(true);
    expect(isCommandSurfaceApp(remoteApp('opencode', AdapterKind.OpenCode, 'OpenCode'))).toBe(true);
    expect(isCommandSurfaceApp(remoteApp('claude-code', AdapterKind.ClaudeCode, 'Claude Code'))).toBe(true);
    expect(isCommandSurfaceApp(remoteApp('gemini-cli', AdapterKind.GeminiCli, 'Gemini CLI'))).toBe(true);
    expect(isCommandSurfaceApp(remoteApp('codex', AdapterKind.Mirror, 'Codex'))).toBe(false);
    expect(isCommandSurfaceApp(remoteApp('cursor', AdapterKind.Cursor, 'Cursor'))).toBe(false);
    expect(isCommandSurfaceApp(remoteApp('claude-desktop', AdapterKind.ClaudeDesktop, 'Claude'))).toBe(false);
  });

  it('keeps Terminal opening and empty states short', () => {
    expect(terminalLoadingText('Terminal')).toBe('opening terminal session...');
    expect(terminalEmptyText()).toBe('waiting for terminal output');
    expect(terminalLoadingText('Terminal')).not.toMatch(/pty|shell|adapter|relay|websocket/i);
    expect(terminalEmptyText()).not.toMatch(/pty|shell|adapter|relay|websocket/i);
  });

  it('uses Terminal-specific status labels', () => {
    expect(terminalStatusLabel(AgentStatus.Idle, false)).toBe('ready');
    expect(terminalStatusLabel(AgentStatus.Done, false)).toBe('ready');
    expect(terminalStatusLabel(AgentStatus.Working, false)).toBe('running');
    expect(terminalStatusLabel(AgentStatus.WaitingInput, false)).toBe('waiting');
    expect(terminalStatusLabel(AgentStatus.AwaitingApproval, false)).toBe('waiting');
    expect(terminalStatusLabel(AgentStatus.Error, false)).toBe('error');
    expect(terminalStatusLabel(AgentStatus.Disconnected, false)).toBe('offline');
    expect(terminalStatusLabel(AgentStatus.Idle, true)).toBe('syncing');
    expect(terminalStatusLabel(AgentStatus.Idle, false, true)).toBe('offline');
    expect(terminalStatusLabel(AgentStatus.Working, false, true)).toBe('offline');
  });

  it('shows the selected Terminal session label when the Mac publishes one', () => {
    expect(
      selectedTerminalSessionLabel({
        agentId: 'terminal',
        agentLabel: 'Terminal',
        adapterKind: AdapterKind.Terminal,
        status: AgentStatus.Working,
        statusDetail: 'running command',
        recentMessages: [],
        lastActivityUnixMs: 0,
        position: { row: 0, col: 0, rowSpan: 1, colSpan: 1 },
        hasVideoTrack: false,
        availableTargets: [
          {
            targetId: 'terminal-session:glasstunnel-terminal',
            label: 'Default Terminal',
            subtitle: 'Shared with Terminal.app',
            selected: true,
            threadId: 'terminal-session:glasstunnel-terminal',
            threadLabel: 'Default Terminal',
            targetKind: 'session',
            isActive: true,
          },
        ],
      }),
    ).toBe('Default Terminal');
  });

  it('does not treat coding-app thread targets as Terminal session labels', () => {
    expect(
      selectedTerminalSessionLabel({
        agentId: 'codex',
        agentLabel: 'Codex',
        adapterKind: AdapterKind.CodexCli,
        status: AgentStatus.Idle,
        statusDetail: 'ready',
        recentMessages: [],
        lastActivityUnixMs: 0,
        position: { row: 0, col: 0, rowSpan: 1, colSpan: 1 },
        hasVideoTrack: false,
        availableTargets: [
          {
            targetId: 'thread-1',
            label: 'glasstunnel',
            subtitle: 'Glasstunnel 1',
            selected: true,
            targetKind: 'thread',
          },
        ],
      }),
    ).toBeNull();
  });

  it('blocks agent actions while state is unavailable or failed', () => {
    expect(agentInteractionUnavailable(AgentStatus.Idle, true)).toBe(true);
    expect(agentInteractionUnavailable(AgentStatus.Disconnected, false)).toBe(true);
    expect(agentInteractionUnavailable(AgentStatus.Error, false)).toBe(true);
    expect(agentInteractionUnavailable(AgentStatus.Idle, false, true)).toBe(true);
    expect(agentInteractionUnavailable(AgentStatus.Working, false, true)).toBe(true);
    expect(agentInteractionUnavailable(AgentStatus.Idle, false)).toBe(false);
    expect(agentInteractionUnavailable(AgentStatus.Working, false)).toBe(false);
    expect(agentInteractionUnavailable(AgentStatus.WaitingInput, false)).toBe(false);
  });

  it('blocks runtime restarts while an agent is working', () => {
    expect(runtimeControlsUnavailable(AgentStatus.Working, false)).toBe(true);
    expect(runtimeControlsUnavailable(AgentStatus.Working, false, false, 'running prompt')).toBe(true);
    expect(runtimeControlsUnavailable(AgentStatus.Working, false, false, 'authenticating')).toBe(true);
    expect(runtimeControlsUnavailable(AgentStatus.Idle, false)).toBe(false);
    expect(runtimeControlsUnavailable(AgentStatus.Done, false)).toBe(false);
    expect(runtimeControlsUnavailable(AgentStatus.WaitingInput, false)).toBe(false);
    expect(runtimeControlsUnavailable(AgentStatus.Idle, true)).toBe(true);
    expect(runtimeControlsUnavailable(AgentStatus.Idle, false, true)).toBe(true);
  });

  it('keeps runtime controls available after a settings update acknowledgement', () => {
    expect(runtimeControlsUnavailable(AgentStatus.Working, false, false, 'settings updated')).toBe(false);
    expect(runtimeControlsUnavailable(AgentStatus.Working, true, false, 'settings updated')).toBe(true);
    expect(runtimeControlsUnavailable(AgentStatus.Working, false, true, 'settings updated')).toBe(true);
  });

  it('treats Terminal session switching as a syncing state', () => {
    expect(terminalSwitchingSession(AgentStatus.Working, 'opening Default Terminal')).toBe(true);
    expect(terminalSwitchingSession(AgentStatus.Working, 'Opening Terminal 2')).toBe(true);
    expect(terminalSwitchingSession(AgentStatus.Working, 'opening Next session')).toBe(true);
    expect(terminalSwitchingSession(AgentStatus.Working, 'Switching session')).toBe(true);
    expect(terminalSwitchingSession(AgentStatus.Working, 'running command')).toBe(false);
    expect(terminalSwitchingSession(AgentStatus.Idle, 'opening Default Terminal')).toBe(false);
  });

  it('blocks OpenCode prompts while target selection is still syncing', () => {
    const switchingTarget = terminalSwitchingSession(AgentStatus.Working, 'opening Next session');

    expect(switchingTarget).toBe(true);
    expect(commandSurfaceInteractionUnavailable(AgentStatus.Working, false, false, switchingTarget)).toBe(true);
    expect(commandSurfaceInteractionUnavailable(AgentStatus.Working, false, false, false)).toBe(true);
    expect(commandSurfaceInteractionUnavailable(AgentStatus.Working, false, false, false, true)).toBe(false);
  });

  it('blocks Cursor prompts while selected chat sync is unverified', () => {
    expect(
      cursorTargetInteractionUnavailable({
        adapterKind: AdapterKind.Cursor,
        status: AgentStatus.Working,
        statusDetail: 'syncing Cursor chat 2',
      }),
    ).toBe(true);
    expect(
      cursorTargetInteractionUnavailable({
        adapterKind: AdapterKind.Cursor,
        status: AgentStatus.WaitingInput,
        statusDetail: 'Open this chat in Cursor to send',
      }),
    ).toBe(true);
    expect(
      cursorTargetInteractionUnavailable({
        adapterKind: AdapterKind.Cursor,
        status: AgentStatus.Working,
        statusDetail: 'input delivered',
      }),
    ).toBe(false);
    expect(
      cursorTargetInteractionUnavailable({
        adapterKind: AdapterKind.OpenCode,
        status: AgentStatus.Working,
        statusDetail: 'syncing Cursor chat 2',
      }),
    ).toBe(false);
  });

  it('blocks Cursor prompts when a selected target is browse-only even if status text is stale', () => {
    expect(
      cursorTargetInteractionUnavailable({
        adapterKind: AdapterKind.Cursor,
        status: AgentStatus.Idle,
        statusDetail: '',
        availableTargets: [
          { targetId: 'cursor-chat-1', label: 'Current chat', subtitle: '', selected: false, isActive: true },
          { targetId: 'cursor-chat-2', label: 'Saved chat', subtitle: '', selected: true, isActive: false },
        ],
      }),
    ).toBe(true);
    expect(
      cursorTargetInteractionUnavailable({
        adapterKind: AdapterKind.Cursor,
        status: AgentStatus.Idle,
        statusDetail: '',
        availableTargets: [
          { targetId: 'cursor-chat-1', label: 'Current chat', subtitle: '', selected: true, isActive: true },
        ],
      }),
    ).toBe(false);
  });

  it('blocks Codex prompts until the selected desktop chat is active', () => {
    expect(
      codexTargetInteractionUnavailable({
        adapterKind: AdapterKind.Mirror,
        availableTargets: [
          { targetId: 'codex-chat-1', label: 'Current chat', subtitle: '', selected: false, isActive: true },
          { targetId: 'codex-chat-2', label: 'Selected chat', subtitle: '', selected: true, isActive: false },
        ],
      }),
    ).toBe(true);
    expect(
      codexTargetInteractionUnavailable({
        adapterKind: AdapterKind.Mirror,
        availableTargets: [
          { targetId: 'codex-chat-1', label: 'Current chat', subtitle: '', selected: true, isActive: true },
        ],
      }),
    ).toBe(false);
  });

  it('makes selected Terminal session targets inert instead of toggle-like', () => {
    expect(terminalTargetButtonState({ label: 'Default Terminal', selected: true }, false)).toEqual({
      ariaDisabled: true,
      ariaLabel: 'Current session: Default Terminal',
      ariaPressed: true,
      canSelect: false,
    });
    expect(terminalTargetButtonState({ label: 'Terminal 2', selected: false }, false)).toEqual({
      ariaDisabled: false,
      ariaLabel: 'Switch to Terminal 2',
      ariaPressed: false,
      canSelect: true,
    });
    expect(terminalTargetButtonState({ label: 'Terminal 2', selected: false }, true)).toMatchObject({
      ariaDisabled: true,
      canSelect: false,
    });
  });

  it('describes Cursor targets as browsable chats, not switchable sessions', () => {
    const currentChat = {
      label: 'glasstunnel',
      selected: true,
      threadLabel: 'Glass Tunnel 1',
      projectLabel: 'glasstunnel',
      targetKind: 'thread' as const,
    };
    const previousChat = {
      label: 'old-chat',
      selected: false,
      threadLabel: 'Bug bash notes',
      projectLabel: 'glasstunnel',
      targetKind: 'thread' as const,
    };

    expect(commandTargetButtonDisplay(currentChat, AdapterKind.Cursor)).toEqual({
      label: 'Glass Tunnel 1',
      subtitle: 'Current chat',
    });
    expect(commandTargetButtonState(currentChat, false, AdapterKind.Cursor)).toEqual({
      ariaDisabled: true,
      ariaLabel: 'Current chat: Glass Tunnel 1',
      ariaPressed: true,
      canSelect: false,
    });
    expect(commandTargetButtonDisplay(previousChat, AdapterKind.Cursor)).toEqual({
      label: 'Bug bash notes',
      subtitle: 'Browse only',
    });
    expect(commandTargetButtonState(previousChat, false, AdapterKind.Cursor)).toEqual({
      ariaDisabled: false,
      ariaLabel: 'Browse chat: Bug bash notes',
      ariaPressed: false,
      canSelect: true,
    });
  });

  it('does not call a locally selected Cursor target current until Cursor confirms it is active', () => {
    const cursorActiveChat = {
      label: 'current-chat',
      selected: false,
      isActive: true,
      threadLabel: 'Current Cursor chat',
      projectLabel: 'glasstunnel',
      targetKind: 'thread' as const,
    };
    const localOnlyChat = {
      label: 'old-chat',
      selected: true,
      isActive: false,
      threadLabel: 'Bug bash notes',
      projectLabel: 'glasstunnel',
      targetKind: 'thread' as const,
    };

    expect(commandTargetButtonDisplay(cursorActiveChat, AdapterKind.Cursor)).toEqual({
      label: 'Current Cursor chat',
      subtitle: 'Current chat',
    });
    expect(commandTargetButtonDisplay(localOnlyChat, AdapterKind.Cursor)).toEqual({
      label: 'Bug bash notes',
      subtitle: 'Browse only',
    });
    expect(commandTargetButtonState(localOnlyChat, false, AdapterKind.Cursor)).toEqual({
      ariaDisabled: true,
      ariaLabel: 'Browsing chat: Bug bash notes',
      ariaPressed: true,
      canSelect: false,
    });
  });

  it('keeps an unverified Codex selection actionable and explicit', () => {
    const selectedChat = {
      label: 'old-chat',
      selected: true,
      isActive: false,
      threadLabel: 'Bug bash notes',
      projectLabel: 'glasstunnel',
      targetKind: 'thread' as const,
    };

    expect(commandTargetButtonDisplay(selectedChat, AdapterKind.Mirror)).toEqual({
      label: 'Bug bash notes',
      subtitle: 'Open this chat',
    });
    expect(commandTargetButtonState(selectedChat, false, AdapterKind.Mirror)).toEqual({
      ariaDisabled: false,
      ariaLabel: 'Open chat: Bug bash notes',
      ariaPressed: true,
      canSelect: true,
    });
  });

  it('uses OpenCode thread titles for command target buttons', () => {
    const openCodeTarget = {
      label: 'glasstunnel',
      subtitle: '/Users/developer/Documents/GitHub2/glasstunnel',
      selected: false,
      threadLabel: 'Glass Tunnel 1',
      projectLabel: 'glasstunnel',
      targetKind: 'thread' as const,
    };

    expect(commandTargetButtonDisplay(openCodeTarget)).toEqual({
      label: 'Glass Tunnel 1',
      subtitle: 'glasstunnel',
    });
    expect(terminalTargetButtonState(openCodeTarget, false)).toMatchObject({
      ariaLabel: 'Switch to Glass Tunnel 1',
      canSelect: true,
    });
  });
});

function remoteApp(remoteAppId: string, adapterKind: AdapterKind, displayName: string): RemoteApp {
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
