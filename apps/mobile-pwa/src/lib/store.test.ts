import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  hasLinkCodeParam,
  mergeClaimedHost,
  mergeLocalOptimisticMessages,
  shouldEnterHostLinkFlow,
  useAppStore,
} from './store';
import { SCREEN_STREAM_CONNECTING_MESSAGE } from './screenStreamStatus';
import { AdapterKind, AgentStatus, ChatRole, type AgentTargetOption } from '@glasstunnel/protocol';

describe('app store screen video lifecycle', () => {
  afterEach(() => {
    useAppStore.setState({
      videoStreams: {},
      relayScreenFrames: {},
      agents: {},
      peer: null,
      signaling: null,
      relay: null,
      error: null,
    });
  });

  it('closes active video transport when stopping screen video', () => {
    const close = vi.fn();
    const disconnect = vi.fn();
    const stopTrack = vi.fn();
    const stream = {
      getTracks: () => [{ stop: stopTrack }],
    } as unknown as MediaStream;

    useAppStore.setState({
      peer: { close } as unknown as ReturnType<typeof useAppStore.getState>['peer'],
      signaling: { disconnect } as unknown as ReturnType<typeof useAppStore.getState>['signaling'],
      videoStreams: { screen: stream },
      relayScreenFrames: {
        screen: {
          agentId: 'screen',
          type: 'relay_screen_frame',
          mimeType: 'image/jpeg',
          width: 1,
          height: 1,
          bytes: 'AA==',
          sequence: 1,
          atUnixMs: 10_000,
        },
      },
      error: SCREEN_STREAM_CONNECTING_MESSAGE,
    });

    useAppStore.getState().stopVideoPeer('screen');

    expect(close).toHaveBeenCalledOnce();
    expect(disconnect).toHaveBeenCalledOnce();
    expect(stopTrack).toHaveBeenCalledOnce();
    expect(useAppStore.getState().peer).toBeNull();
    expect(useAppStore.getState().signaling).toBeNull();
    expect(useAppStore.getState().videoStreams.screen).toBeUndefined();
    expect(useAppStore.getState().relayScreenFrames.screen).toBeUndefined();
    expect(useAppStore.getState().error).toBeNull();
  });

  it('delivers normalized screen pointer input through the relay', () => {
    const sendScreenPointer = vi.fn(() => true);
    useAppStore.setState({
      relay: { sendScreenPointer } as unknown as ReturnType<typeof useAppStore.getState>['relay'],
      peer: null,
    });

    useAppStore.getState().sendScreenPointer('screen', 0.25, 0.75, 'doubleClick');

    expect(sendScreenPointer).toHaveBeenCalledWith({
      agentId: 'screen',
      x: 0.25,
      y: 0.75,
      action: 'doubleClick',
    });
  });

  it('renames a Terminal session optimistically after command delivery', () => {
    const sendTargetRename = vi.fn(() => true);
    useAppStore.setState({
      relay: { sendTargetRename } as unknown as ReturnType<typeof useAppStore.getState>['relay'],
      agents: {
        terminal: {
          agentId: 'terminal',
          agentLabel: 'Terminal',
          adapterKind: AdapterKind.Terminal,
          status: AgentStatus.Idle,
          statusDetail: 'ready',
          recentMessages: [],
          lastActivityUnixMs: 10_000,
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
            },
          ],
        },
      },
    });

    const delivered = useAppStore.getState().renameTarget(
      'terminal',
      'terminal-session:glasstunnel-terminal',
      '  Release console  ',
    );

    expect(delivered).toBe(true);
    expect(sendTargetRename).toHaveBeenCalledWith({
      agentId: 'terminal',
      targetId: 'terminal-session:glasstunnel-terminal',
      label: 'Release console',
    });
    expect(useAppStore.getState().agents.terminal.availableTargets?.[0]).toMatchObject({
      label: 'Release console',
      threadLabel: 'Release console',
    });
  });

  it('marks an interrupt as requested immediately after relay delivery', () => {
    const sendInterrupt = vi.fn(() => true);
    useAppStore.setState({
      relay: { sendInterrupt } as unknown as ReturnType<typeof useAppStore.getState>['relay'],
      remoteApps: [
        {
          remoteAppId: 'codex-cli',
          displayName: 'Codex CLI',
          adapterKind: AdapterKind.CodexCli,
          agentId: 'codex-cli',
          enabled: true,
          available: true,
          status: AgentStatus.Working,
          statusDetail: 'running',
          windowTitle: '',
          applicationBundleId: '',
          hasVideo: false,
        },
      ],
      agents: {
        'codex-cli': {
          agentId: 'codex-cli',
          agentLabel: 'Codex CLI',
          adapterKind: AdapterKind.CodexCli,
          status: AgentStatus.Working,
          statusDetail: 'running',
          recentMessages: [],
          lastActivityUnixMs: 10_000,
          position: { row: 0, col: 0, rowSpan: 1, colSpan: 1 },
          hasVideoTrack: false,
        },
      },
    });

    useAppStore.getState().sendInterrupt('codex-cli');

    expect(sendInterrupt).toHaveBeenCalledWith({ agentId: 'codex-cli' });
    expect(useAppStore.getState().agents['codex-cli']).toMatchObject({
      status: AgentStatus.Working,
      statusDetail: 'stop requested',
    });
    expect(useAppStore.getState().agents['codex-cli'].recentMessages.at(-1)).toMatchObject({
      role: ChatRole.System,
      text: 'Stop requested.',
    });
  });

  it('does not send runtime settings while a CLI prompt is running', () => {
    const sendRuntimeSettingsUpdate = vi.fn(() => true);
    const runtimeControls = {
      modelId: 'gpt-5.5',
      modelLabel: 'GPT-5.5',
      modelOptions: [
        { id: 'gpt-5.5', label: 'GPT-5.5' },
        { id: 'gpt-5.4', label: 'GPT-5.4' },
      ],
      reasoningEffort: 'xhigh',
      reasoningEffortLabel: 'Extra high',
      reasoningEffortOptions: [{ id: 'xhigh', label: 'Extra high' }],
      fastMode: false,
      supportsModelSelection: true,
      supportsReasoningEffort: true,
      supportsFastMode: true,
      editable: true,
      appliesOn: 'immediate' as const,
    };
    useAppStore.setState({
      relay: { sendRuntimeSettingsUpdate } as unknown as ReturnType<typeof useAppStore.getState>['relay'],
      agents: {
        'codex-cli': {
          agentId: 'codex-cli',
          agentLabel: 'Codex CLI',
          adapterKind: AdapterKind.CodexCli,
          status: AgentStatus.Working,
          statusDetail: 'running prompt',
          recentMessages: [],
          lastActivityUnixMs: 10_000,
          position: { row: 0, col: 0, rowSpan: 1, colSpan: 1 },
          hasVideoTrack: false,
          runtimeControls,
        },
      },
    });

    const delivered = useAppStore.getState().updateRuntimeSettings('codex-cli', {
      modelId: 'gpt-5.4',
      fastMode: true,
    });

    expect(delivered).toBe(false);
    expect(sendRuntimeSettingsUpdate).not.toHaveBeenCalled();
    expect(useAppStore.getState().agents['codex-cli']).toMatchObject({
      status: AgentStatus.Working,
      statusDetail: 'running prompt',
      runtimeControls,
    });
  });

  it('does not send runtime settings for read-only Cursor controls', () => {
    const sendRuntimeSettingsUpdate = vi.fn(() => true);
    const runtimeControls = {
      modelOptions: [],
      reasoningEffortOptions: [],
      supportsModelSelection: false,
      supportsReasoningEffort: false,
      supportsFastMode: false,
      editable: false,
      appliesOn: 'managed_locally' as const,
      note: 'Managed in Cursor',
    };
    useAppStore.setState({
      relay: { sendRuntimeSettingsUpdate } as unknown as ReturnType<typeof useAppStore.getState>['relay'],
      peer: null,
      agents: {
        cursor: {
          agentId: 'cursor',
          agentLabel: 'Cursor',
          adapterKind: AdapterKind.Cursor,
          status: AgentStatus.Idle,
          statusDetail: 'ready',
          recentMessages: [],
          lastActivityUnixMs: 10_000,
          position: { row: 0, col: 0, rowSpan: 1, colSpan: 1 },
          hasVideoTrack: false,
          runtimeControls,
        },
      },
    });

    const delivered = useAppStore.getState().updateRuntimeSettings('cursor', {
      modelId: 'composer-2.5-fast',
    });

    expect(delivered).toBe(false);
    expect(sendRuntimeSettingsUpdate).not.toHaveBeenCalled();
    expect(useAppStore.getState().agents.cursor).toMatchObject({
      status: AgentStatus.Idle,
      statusDetail: 'ready',
      runtimeControls,
    });
  });

  it('does not send runtime settings for read-only Cursor Agent controls', () => {
    const sendRuntimeSettingsUpdate = vi.fn(() => true);
    const runtimeControls = {
      modelId: 'gpt-5.4-nano-none',
      modelLabel: 'GPT 5.4 Nano',
      modelOptions: [{ id: 'gpt-5.4-nano-none', label: 'GPT 5.4 Nano' }],
      reasoningEffortOptions: [],
      supportsModelSelection: true,
      supportsReasoningEffort: false,
      supportsFastMode: false,
      editable: false,
      appliesOn: 'managed_locally' as const,
      note: 'Ask mode only. File edits are not enabled.',
    };
    useAppStore.setState({
      relay: { sendRuntimeSettingsUpdate } as unknown as ReturnType<typeof useAppStore.getState>['relay'],
      peer: null,
      agents: {
        'cursor-agent': {
          agentId: 'cursor-agent',
          agentLabel: 'Cursor Agent',
          adapterKind: AdapterKind.CursorAgent,
          status: AgentStatus.Idle,
          statusDetail: 'ready',
          recentMessages: [],
          lastActivityUnixMs: 10_000,
          position: { row: 0, col: 0, rowSpan: 1, colSpan: 1 },
          hasVideoTrack: false,
          runtimeControls,
        },
      },
    });

    const delivered = useAppStore.getState().updateRuntimeSettings('cursor-agent', {
      modelId: 'gpt-5.4-nano-none',
    });

    expect(delivered).toBe(false);
    expect(sendRuntimeSettingsUpdate).not.toHaveBeenCalled();
    expect(useAppStore.getState().agents['cursor-agent']).toMatchObject({
      status: AgentStatus.Idle,
      statusDetail: 'ready',
      runtimeControls,
    });
  });

  it('returns delivery success and appends an optimistic prompt after sending text', () => {
    const sendUserInput = vi.fn(() => true);
    useAppStore.setState({
      relay: { sendUserInput } as unknown as ReturnType<typeof useAppStore.getState>['relay'],
      peer: null,
      agents: {
        opencode: agentSnapshot('opencode', []),
      },
    });

    const delivered = useAppStore.getState().sendText('opencode', '  hello from mobile  ', true);

    expect(delivered).toBe(true);
    expect(sendUserInput).toHaveBeenCalledWith({
      agentId: 'opencode',
      text: 'hello from mobile',
      submitOnSend: true,
    });
    expect(useAppStore.getState().agents.opencode.recentMessages.at(-1)).toMatchObject({
      role: ChatRole.User,
      text: 'hello from mobile',
    });
  });

  it('returns delivery failure so callers can keep unsent text in the composer', () => {
    useAppStore.setState({
      relay: null,
      peer: null,
      agents: {
        opencode: agentSnapshot('opencode', []),
      },
    });

    const delivered = useAppStore.getState().sendText('opencode', 'still needs sending', true);

    expect(delivered).toBe(false);
    expect(useAppStore.getState().agents.opencode.recentMessages.at(-1)).toMatchObject({
      role: ChatRole.System,
      text: 'Not sent. Connection to your Mac is not open. Reconnect and try again.',
    });
  });

  it('does not send Cursor prompts while target selection is still syncing', () => {
    const sendUserInput = vi.fn(() => true);
    useAppStore.setState({
      relay: { sendUserInput } as unknown as ReturnType<typeof useAppStore.getState>['relay'],
      peer: null,
      agents: {
        cursor: {
          ...agentSnapshot('cursor', [], AdapterKind.Cursor),
          status: AgentStatus.Working,
          statusDetail: 'syncing Cursor chat 2',
        },
      },
    });

    const delivered = useAppStore.getState().sendText('cursor', 'do the wrong thing', true);

    expect(delivered).toBe(false);
    expect(sendUserInput).not.toHaveBeenCalled();
    expect(useAppStore.getState().agents.cursor.recentMessages.at(-1)).toMatchObject({
      role: ChatRole.System,
      text: 'Not sent. Open this chat in Cursor on your Mac to send.',
    });
  });

  it('does not send Cursor prompts after the Mac marks a selected chat browse-only', () => {
    const sendUserInput = vi.fn(() => true);
    useAppStore.setState({
      relay: { sendUserInput } as unknown as ReturnType<typeof useAppStore.getState>['relay'],
      peer: null,
      agents: {
        cursor: {
          ...agentSnapshot('cursor', [], AdapterKind.Cursor),
          status: AgentStatus.WaitingInput,
          statusDetail: 'Open this chat in Cursor to send',
        },
      },
    });

    const delivered = useAppStore.getState().sendText('cursor', 'do the wrong thing', true);

    expect(delivered).toBe(false);
    expect(sendUserInput).not.toHaveBeenCalled();
    expect(useAppStore.getState().agents.cursor.recentMessages.at(-1)).toMatchObject({
      role: ChatRole.System,
      text: 'Not sent. Open this chat in Cursor on your Mac to send.',
    });
  });

  it('does not send Cursor prompts when target state is browse-only but status text is stale', () => {
    const sendUserInput = vi.fn(() => true);
    useAppStore.setState({
      relay: { sendUserInput } as unknown as ReturnType<typeof useAppStore.getState>['relay'],
      peer: null,
      agents: {
        cursor: {
          ...agentSnapshot('cursor', [], AdapterKind.Cursor),
          status: AgentStatus.Idle,
          statusDetail: '',
          availableTargets: [
            {
              targetId: 'cursor-chat-1',
              label: 'Current chat',
              subtitle: 'Cursor',
              selected: false,
              threadId: 'cursor-chat-1',
              threadLabel: 'Current chat',
              targetKind: 'thread',
              isActive: true,
            },
            {
              targetId: 'cursor-chat-2',
              label: 'Saved chat',
              subtitle: 'Cursor',
              selected: true,
              threadId: 'cursor-chat-2',
              threadLabel: 'Saved chat',
              targetKind: 'thread',
              isActive: false,
            },
          ],
        },
      },
    });

    const delivered = useAppStore.getState().sendText('cursor', 'do the wrong thing', true);

    expect(delivered).toBe(false);
    expect(sendUserInput).not.toHaveBeenCalled();
    expect(useAppStore.getState().agents.cursor.recentMessages.at(-1)).toMatchObject({
      role: ChatRole.System,
      text: 'Not sent. Open this chat in Cursor on your Mac to send.',
    });
  });

  it('does not send Codex prompts to a selected chat that the desktop has not activated', () => {
    const sendUserInput = vi.fn(() => true);
    useAppStore.setState({
      relay: { sendUserInput } as unknown as ReturnType<typeof useAppStore.getState>['relay'],
      peer: null,
      agents: {
        codex: {
          ...agentSnapshot('codex', [], AdapterKind.Mirror),
          availableTargets: [
            {
              targetId: 'codex-chat-2',
              label: 'Selected chat',
              subtitle: 'glasstunnel',
              selected: true,
              threadId: 'codex-chat-2',
              threadLabel: 'Selected chat',
              targetKind: 'thread',
              isActive: false,
            },
          ],
        },
      },
    });

    const delivered = useAppStore.getState().sendText('codex', 'do not misroute this', true);

    expect(delivered).toBe(false);
    expect(sendUserInput).not.toHaveBeenCalled();
    expect(useAppStore.getState().agents.codex.recentMessages.at(-1)).toMatchObject({
      role: ChatRole.System,
      text: 'Not sent. Open this chat in Codex on your Mac to send.',
    });
  });

  it('keeps a recent submitted command visible across stale incoming snapshots', () => {
    const incoming = agentSnapshot('opencode', [
      {
        messageId: 'host-old',
        role: ChatRole.Assistant,
        text: 'OpenCode context synced',
        atUnixMs: 10_000,
        redacted: false,
        pendingToolCalls: [],
        redactionReasons: [],
      },
    ]);
    const current = agentSnapshot('opencode', [
      ...(incoming.recentMessages ?? []),
      {
        messageId: 'local-prompt',
        role: ChatRole.User,
        text: 'Reply with exactly GTIOSOPEN123 and nothing else.',
        atUnixMs: 20_000,
        redacted: false,
        pendingToolCalls: [],
        redactionReasons: [],
      },
    ]);

    const merged = mergeLocalOptimisticMessages(current, incoming, 25_000);

    expect(merged.recentMessages.map((message) => message.text)).toEqual([
      'OpenCode context synced',
      'Reply with exactly GTIOSOPEN123 and nothing else.',
    ]);
  });

  it('drops stale local submitted commands after the optimism window expires', () => {
    const incoming = agentSnapshot('opencode', []);
    const current = agentSnapshot('opencode', [
      {
        messageId: 'local-prompt',
        role: ChatRole.User,
        text: 'old prompt',
        atUnixMs: 20_000,
        redacted: false,
        pendingToolCalls: [],
        redactionReasons: [],
      },
    ]);

    const merged = mergeLocalOptimisticMessages(current, incoming, 90_001);

    expect(merged.recentMessages).toEqual([]);
  });

  it('drops stale host startup status once real OpenCode history arrives', () => {
    const incoming = agentSnapshot('opencode', [
      {
        messageId: 'host-history',
        role: ChatRole.Assistant,
        text: 'GT_OPENCODE_SESSION_SWITCH_20260624',
        atUnixMs: 10_000,
        redacted: false,
        pendingToolCalls: [],
        redactionReasons: [],
      },
    ]);
    const current = agentSnapshot('opencode', [
      {
        messageId: 'opencode-remote-app-20000',
        role: ChatRole.System,
        text: 'Opening OpenCode on this Mac.',
        atUnixMs: 20_000,
        redacted: false,
        pendingToolCalls: [],
        redactionReasons: [],
      },
    ]);

    const merged = mergeLocalOptimisticMessages(current, incoming, 25_000);

    expect(merged.recentMessages.map((message) => message.text)).toEqual([
      'GT_OPENCODE_SESSION_SWITCH_20260624',
    ]);
  });

  it('keeps a local Stop request visible across stale incoming snapshots', () => {
    const incoming = agentSnapshot('opencode', [
      {
        messageId: 'host-old',
        role: ChatRole.Assistant,
        text: 'OpenCode context synced',
        atUnixMs: 10_000,
        redacted: false,
        pendingToolCalls: [],
        redactionReasons: [],
      },
    ]);
    const current = agentSnapshot('opencode', [
      ...(incoming.recentMessages ?? []),
      {
        messageId: 'local-stop',
        role: ChatRole.System,
        text: 'Stop requested.',
        atUnixMs: 20_000,
        redacted: false,
        pendingToolCalls: [],
        redactionReasons: [],
      },
    ]);

    const merged = mergeLocalOptimisticMessages(current, incoming, 25_000);

    expect(merged.recentMessages.map((message) => message.text)).toEqual([
      'OpenCode context synced',
      'Stop requested.',
    ]);
  });

  it('does not mark an OpenCode session selected when target delivery fails', () => {
    const sendTargetSelection = vi.fn(() => false);
    useAppStore.setState({
      relay: { sendTargetSelection } as unknown as ReturnType<typeof useAppStore.getState>['relay'],
      peer: null,
      agents: {
        opencode: {
          ...agentSnapshot('opencode', []),
          availableTargets: openCodeSessionTargets(),
        },
      },
    });

    const delivered = useAppStore.getState().selectTarget('opencode', 'ses_next');

    expect(delivered).toBe(false);
    expect(sendTargetSelection).toHaveBeenCalledWith({ agentId: 'opencode', targetId: 'ses_next' });
    expect(useAppStore.getState().agents.opencode.availableTargets).toMatchObject([
      { targetId: 'ses_current', selected: true },
      { targetId: 'ses_next', selected: false },
    ]);
    expect(useAppStore.getState().agents.opencode).toMatchObject({
      status: AgentStatus.WaitingInput,
      statusDetail: 'connection not open',
    });
    expect(useAppStore.getState().agents.opencode.recentMessages.at(-1)).toMatchObject({
      role: ChatRole.System,
      text: 'Not sent. Connection to your Mac is not open. Reconnect and try again.',
    });
  });

  it('marks an OpenCode session as opening after target delivery succeeds', () => {
    const sendTargetSelection = vi.fn(() => true);
    useAppStore.setState({
      relay: { sendTargetSelection } as unknown as ReturnType<typeof useAppStore.getState>['relay'],
      peer: null,
      agents: {
        opencode: {
          ...agentSnapshot('opencode', []),
          availableTargets: openCodeSessionTargets(),
        },
      },
    });

    const delivered = useAppStore.getState().selectTarget('opencode', 'ses_next');

    expect(delivered).toBe(true);
    expect(sendTargetSelection).toHaveBeenCalledWith({ agentId: 'opencode', targetId: 'ses_next' });
    expect(useAppStore.getState().agents.opencode).toMatchObject({
      status: AgentStatus.Working,
      statusDetail: 'opening Next session',
    });
    expect(useAppStore.getState().agents.opencode.availableTargets).toMatchObject([
      { targetId: 'ses_current', selected: false },
      { targetId: 'ses_next', selected: true },
    ]);
  });

  it('does not mark a Cursor chat selected when target delivery fails', () => {
    const sendTargetSelection = vi.fn(() => false);
    useAppStore.setState({
      relay: { sendTargetSelection } as unknown as ReturnType<typeof useAppStore.getState>['relay'],
      peer: null,
      agents: {
        cursor: {
          ...agentSnapshot('cursor', [], AdapterKind.Cursor),
          agentLabel: 'Cursor',
          availableTargets: cursorChatTargets(),
        },
      },
    });

    const delivered = useAppStore.getState().selectTarget('cursor', 'cursor-chat-2');

    expect(delivered).toBe(false);
    expect(sendTargetSelection).toHaveBeenCalledWith({ agentId: 'cursor', targetId: 'cursor-chat-2' });
    expect(useAppStore.getState().agents.cursor.availableTargets).toMatchObject([
      { targetId: 'cursor-chat-1', selected: true },
      { targetId: 'cursor-chat-2', selected: false },
    ]);
    expect(useAppStore.getState().agents.cursor).toMatchObject({
      status: AgentStatus.WaitingInput,
      statusDetail: 'connection not open',
    });
  });

  it('marks a Cursor chat as syncing only after target delivery succeeds', () => {
    const sendTargetSelection = vi.fn(() => true);
    useAppStore.setState({
      relay: { sendTargetSelection } as unknown as ReturnType<typeof useAppStore.getState>['relay'],
      peer: null,
      agents: {
        cursor: {
          ...agentSnapshot('cursor', [], AdapterKind.Cursor),
          agentLabel: 'Cursor',
          availableTargets: cursorChatTargets(),
        },
      },
    });

    const delivered = useAppStore.getState().selectTarget('cursor', 'cursor-chat-2');

    expect(delivered).toBe(true);
    expect(sendTargetSelection).toHaveBeenCalledWith({ agentId: 'cursor', targetId: 'cursor-chat-2' });
    expect(useAppStore.getState().agents.cursor).toMatchObject({
      status: AgentStatus.Working,
      statusDetail: 'syncing Cursor chat 2',
    });
    expect(useAppStore.getState().agents.cursor.availableTargets).toMatchObject([
      { targetId: 'cursor-chat-1', selected: false, isActive: true },
      { targetId: 'cursor-chat-2', selected: true, isActive: false },
    ]);
  });

  it('marks a Codex chat inactive until the Mac confirms the target switch', () => {
    const sendTargetSelection = vi.fn(() => true);
    useAppStore.setState({
      relay: { sendTargetSelection } as unknown as ReturnType<typeof useAppStore.getState>['relay'],
      peer: null,
      agents: {
        codex: {
          ...agentSnapshot('codex', [], AdapterKind.Mirror),
          agentLabel: 'Codex',
          availableTargets: [
            { targetId: 'codex-chat-1', label: 'Current chat', subtitle: '', selected: true, isActive: true },
            { targetId: 'codex-chat-2', label: 'Next chat', subtitle: '', selected: false, isActive: false },
          ],
        },
      },
    });

    const delivered = useAppStore.getState().selectTarget('codex', 'codex-chat-2');

    expect(delivered).toBe(true);
    expect(useAppStore.getState().agents.codex.availableTargets).toMatchObject([
      { targetId: 'codex-chat-1', selected: false, isActive: true },
      { targetId: 'codex-chat-2', selected: true, isActive: false },
    ]);
  });

  it('blocks Cursor attachment delivery while selected chat sync is unverified', async () => {
    const sendImageAttachment = vi.fn(async () => true);
    const sendFileAttachment = vi.fn(async () => true);
    useAppStore.setState({
      relay: {
        sendImageAttachment,
        sendFileAttachment,
      } as unknown as ReturnType<typeof useAppStore.getState>['relay'],
      peer: null,
      agents: {
        cursor: {
          ...agentSnapshot('cursor', [], AdapterKind.Cursor),
          agentLabel: 'Cursor',
          status: AgentStatus.WaitingInput,
          statusDetail: 'Open this chat in Cursor to send',
          availableTargets: cursorChatTargets(),
        },
      },
    });

    const imageDelivered = await useAppStore.getState().sendImageAttachment('cursor', {
      text: 'attach this',
      filename: 'cursor-note.png',
      mimeType: 'image/png',
      bytes: new Uint8Array([1, 2, 3]),
      submitOnSend: true,
    });
    const fileDelivered = await useAppStore.getState().sendFileAttachmentBatch('cursor', [
      {
        batchId: 'batch-1',
        text: 'attach this file',
        filename: 'cursor-note.txt',
        mimeType: 'text/plain',
        fileIndex: 0,
        fileCount: 1,
        bytes: new Uint8Array([4, 5, 6]),
        submitOnSend: true,
      },
    ]);

    expect(imageDelivered).toBe(false);
    expect(fileDelivered).toBe(false);
    expect(sendImageAttachment).not.toHaveBeenCalled();
    expect(sendFileAttachment).not.toHaveBeenCalled();
    expect(useAppStore.getState().agents.cursor.recentMessages).toEqual([
      expect.objectContaining({
        role: ChatRole.System,
        text: 'Not sent. Open this chat in Cursor on your Mac to send.',
      }),
    ]);
  });
});

describe('app store account link routing', () => {
  it('detects link-code URLs even when they include app deep links', () => {
    expect(hasLinkCodeParam('?app=opencode&linkCode=ABC123')).toBe(true);
    expect(hasLinkCodeParam('?linkCode=ABC123')).toBe(true);
    expect(hasLinkCodeParam('?app=opencode')).toBe(false);
    expect(hasLinkCodeParam('?linkCode=')).toBe(false);
  });

  it('forces already-open workspace tabs into the host-link flow', () => {
    expect(shouldEnterHostLinkFlow('workspace', '?app=opencode&linkCode=ABC123')).toBe(true);
    expect(shouldEnterHostLinkFlow('grid', '?linkCode=ABC123')).toBe(true);
    expect(shouldEnterHostLinkFlow('profile', '?linkCode=ABC123')).toBe(true);
    expect(shouldEnterHostLinkFlow('unlock', '?linkCode=ABC123')).toBe(true);
    expect(shouldEnterHostLinkFlow('hosts', '?linkCode=ABC123')).toBe(false);
    expect(shouldEnterHostLinkFlow('auth', '?linkCode=ABC123')).toBe(false);
    expect(shouldEnterHostLinkFlow('loading', '?linkCode=ABC123')).toBe(false);
    expect(shouldEnterHostLinkFlow('workspace', '?app=opencode')).toBe(false);
  });

  it('makes a newly claimed Mac immediately selectable', () => {
    const oldHost = accountHost('old-host', "Test Mac");
    const claimedHost = accountHost('new-host', 'OpenCode iOS Safari');

    expect(mergeClaimedHost([oldHost], claimedHost).map((host) => host.deviceId)).toEqual([
      'new-host',
      'old-host',
    ]);
    expect(mergeClaimedHost([oldHost, claimedHost], claimedHost).map((host) => host.deviceId)).toEqual([
      'new-host',
      'old-host',
    ]);
  });
});

function agentSnapshot(
  agentId: string,
  recentMessages: ReturnType<typeof useAppStore.getState>['agents'][string]['recentMessages'],
  adapterKind = AdapterKind.OpenCode,
) {
  return {
    agentId,
    agentLabel: agentId,
    adapterKind,
    status: AgentStatus.Idle,
    statusDetail: 'ready',
    recentMessages,
    lastActivityUnixMs: 10_000,
    position: { row: 0, col: 0, rowSpan: 1, colSpan: 1 },
    hasVideoTrack: false,
  };
}

function cursorChatTargets(): AgentTargetOption[] {
  return [
    {
      targetId: 'cursor-chat-1',
      label: 'Cursor chat 1',
      subtitle: 'Cursor',
      selected: true,
      threadId: 'cursor-chat-1',
      threadLabel: 'Cursor chat 1',
      targetKind: 'thread',
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
    },
  ];
}

function accountHost(deviceId: string, label: string) {
  return {
    deviceId,
    label,
    publicKeyB64: `${deviceId}-key`,
    signalingUrl: 'wss://signal.example/signal',
    online: true,
    trusted: true,
    pairedAtUnixMs: 1_781_000_000_000,
  };
}

function openCodeSessionTargets(): AgentTargetOption[] {
  return [
    {
      targetId: 'ses_current',
      label: 'Current project',
      subtitle: '~/Projects/current',
      selected: true,
      projectId: '/Users/developer/Projects/current',
      projectLabel: 'Current project',
      projectPath: '/Users/developer/Projects/current',
      threadId: 'ses_current',
      threadLabel: 'Current session',
      targetKind: 'thread',
      isActive: true,
    },
    {
      targetId: 'ses_next',
      label: 'Next project',
      subtitle: '~/Projects/next',
      selected: false,
      projectId: '/Users/developer/Projects/next',
      projectLabel: 'Next project',
      projectPath: '/Users/developer/Projects/next',
      threadId: 'ses_next',
      threadLabel: 'Next session',
      targetKind: 'thread',
      isActive: false,
    },
  ];
}
