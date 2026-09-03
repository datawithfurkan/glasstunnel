import { describe, expect, it } from 'vitest';
import { ChatMessageKind, ChatRole, type AgentChatMessage } from '@glasstunnel/protocol';
import {
  activitySummary,
  buildTranscript,
  countLines,
  diffLineKind,
  firstMeaningfulLine,
  foldUserPrompt,
  formatElapsed,
  looksLikeDiff,
  readStoredDensity,
  shouldAutoScroll,
  stripAnsi,
  toolRowLabel,
  writeStoredDensity,
} from './transcript';

const T0 = 1_781_312_000_000;

function message(
  id: string,
  role: ChatRole,
  text: string,
  overrides: Partial<AgentChatMessage> = {},
): AgentChatMessage {
  return {
    messageId: id,
    role,
    text,
    atUnixMs: T0,
    redacted: false,
    pendingToolCalls: [],
    ...overrides,
  };
}

function call(id: string, toolName: string, atUnixMs = T0): AgentChatMessage {
  return message(id, ChatRole.Tool, `Using ${toolName}`, {
    atUnixMs,
    pendingToolCalls: [{ toolName, toolCallId: `${id}-call`, summary: `Using ${toolName}` }],
  });
}

describe('buildTranscript', () => {
  it('folds a call and its result into one activity row between the prose', () => {
    const items = buildTranscript([
      message('u1', ChatRole.User, 'run the smoke tests'),
      call('t1', 'Bash'),
      message('t2', ChatRole.Tool, 'ok 12 tests\nall passed\n'),
      message('a1', ChatRole.Assistant, 'All twelve passed.'),
    ]);
    expect(items.map((item) => item.kind)).toEqual(['stamp', 'user', 'activity', 'assistant']);
    const activity = items[2];
    if (activity.kind !== 'activity') throw new Error('expected activity');
    expect(activity.rows).toHaveLength(1);
    expect(activity.rows[0]).toMatchObject({
      toolName: 'Bash',
      pending: false,
      lineCount: 2,
      detail: 'ok 12 tests',
      output: 'ok 12 tests\nall passed\n',
    });
  });

  it('keeps consecutive calls in one block and matches results in order', () => {
    const items = buildTranscript([
      call('t1', 'Read'),
      message('r1', ChatRole.Tool, 'file contents'),
      call('t2', 'Grep'),
      call('t3', 'Bash'),
      message('r2', ChatRole.Tool, 'match'),
    ]);
    expect(items.map((item) => item.kind)).toEqual(['stamp', 'activity']);
    const activity = items[1];
    if (activity.kind !== 'activity') throw new Error('expected activity');
    expect(activity.rows.map((row) => [row.toolName, row.pending])).toEqual([
      ['Read', false],
      ['Grep', false],
      ['Bash', true],
    ]);
    expect(activitySummary(activity.rows)).toBe('3 tool calls · running');
  });

  it('shows the assistant text of a message that also starts tool calls', () => {
    const items = buildTranscript([
      message('a1', ChatRole.Assistant, 'Checking the file first.', {
        pendingToolCalls: [{ toolName: 'Read', toolCallId: 'c1', summary: 'Using Read' }],
      }),
    ]);
    expect(items.map((item) => item.kind)).toEqual(['stamp', 'assistant', 'activity']);
  });

  it('keeps tool output that arrives without a known call', () => {
    const items = buildTranscript([message('r1', ChatRole.Tool, 'stray output')]);
    const activity = items[0];
    if (activity.kind !== 'activity') throw new Error('expected activity');
    expect(toolRowLabel(activity.rows[0])).toEqual({ title: 'Output', meta: '1 line' });
  });

  it('renders system records as events and stamps only after a long gap', () => {
    const items = buildTranscript([
      message('u1', ChatRole.User, 'first', { atUnixMs: T0 }),
      message('s1', ChatRole.System, 'Stopped', { atUnixMs: T0 + 1_000 }),
      message('u2', ChatRole.User, 'second', { atUnixMs: T0 + 5 * 60_000 }),
      message('u3', ChatRole.User, 'third', { atUnixMs: T0 + 15 * 60_000 }),
    ]);
    expect(items.map((item) => item.kind)).toEqual(['stamp', 'user', 'event', 'user', 'stamp', 'user']);
  });

  it('drops empty assistant records', () => {
    expect(buildTranscript([message('a1', ChatRole.Assistant, '   ')])).toEqual([
      { kind: 'stamp', id: 'stamp-a1', atUnixMs: T0 },
    ]);
  });
});

describe('tool row labels', () => {
  it('describes pending, empty, and sized results', () => {
    const base = { id: 'r', toolName: 'Bash', title: '', output: '', detail: '', atUnixMs: T0, redacted: false, truncated: false, durationMs: 0, isError: false };
    expect(toolRowLabel({ ...base, lineCount: 0, pending: true })).toEqual({ title: 'Bash', meta: 'running' });
    expect(toolRowLabel({ ...base, lineCount: 0, pending: false })).toEqual({ title: 'Bash', meta: 'no output' });
    expect(toolRowLabel({ ...base, lineCount: 1, pending: false })).toEqual({ title: 'Bash', meta: '1 line' });
    expect(toolRowLabel({ ...base, lineCount: 9, pending: false })).toEqual({ title: 'Bash', meta: '9 lines' });
  });

  it('takes the first non-empty line and caps its length', () => {
    expect(firstMeaningfulLine('\n\n  hello world  \nmore')).toBe('hello world');
    expect(firstMeaningfulLine('x'.repeat(200))).toHaveLength(96);
    expect(firstMeaningfulLine('')).toBe('');
    expect(countLines('a\nb\n\n')).toBe(2);
    expect(countLines('')).toBe(0);
  });
});

describe('prompt folding and density', () => {
  it('folds prompts longer than six lines', () => {
    const long = Array.from({ length: 9 }, (_, index) => `line ${index + 1}`).join('\n');
    expect(foldUserPrompt(long)).toEqual({
      shown: Array.from({ length: 6 }, (_, index) => `line ${index + 1}`).join('\n'),
      hiddenLines: 3,
    });
    expect(foldUserPrompt('short')).toEqual({ shown: 'short', hiddenLines: 0 });
  });

  it('defaults to focus and survives a broken storage', () => {
    const store = new Map<string, string>();
    const storage = {
      getItem: (key: string) => store.get(key) ?? null,
      setItem: (key: string, value: string) => {
        store.set(key, value);
      },
    };
    expect(readStoredDensity(storage)).toBe('focus');
    writeStoredDensity(storage, 'full');
    expect(readStoredDensity(storage)).toBe('full');
    expect(readStoredDensity(null)).toBe('focus');
    expect(
      readStoredDensity({
        getItem: () => {
          throw new Error('blocked');
        },
      }),
    ).toBe('focus');
  });
});

describe('structured rows from a Mac that sends titles and previews', () => {
  it('pairs results with their calls by id and shows the title, time, and failure', () => {
    const items = buildTranscript([
      message('a1', ChatRole.Assistant, 'Checking.', { kind: ChatMessageKind.Text }),
      message('c1', ChatRole.Tool, 'Using Bash', {
        kind: ChatMessageKind.ToolCall,
        toolName: 'Bash',
        toolCallId: 'toolu_1',
        title: 'git status --short',
        pendingToolCalls: [{ toolName: 'Bash', toolCallId: 'toolu_1', summary: 'Using Bash' }],
      }),
      message('c2', ChatRole.Tool, 'Using Read', {
        kind: ChatMessageKind.ToolCall,
        toolName: 'Read',
        toolCallId: 'toolu_2',
        title: 'Package.swift',
        pendingToolCalls: [{ toolName: 'Read', toolCallId: 'toolu_2', summary: 'Using Read' }],
      }),
      // The second call answers first; ids keep the pairing right.
      message('r2', ChatRole.Tool, '// swift-tools-version', {
        kind: ChatMessageKind.ToolResult,
        toolName: 'Read',
        toolCallId: 'toolu_2',
        outputLineCount: 40,
        truncated: true,
        durationMs: 120,
      }),
      message('r1', ChatRole.Tool, 'fatal: not a git repository', {
        kind: ChatMessageKind.ToolResult,
        toolName: 'Bash',
        toolCallId: 'toolu_1',
        outputLineCount: 1,
        durationMs: 2_400,
        isError: true,
      }),
    ]);
    expect(items.map((item) => item.kind)).toEqual(['stamp', 'assistant', 'activity']);
    const activity = items[2];
    if (activity.kind !== 'activity') throw new Error('expected activity');
    expect(activity.rows.map((row) => [row.toolName, row.title, row.pending, row.lineCount, row.truncated])).toEqual([
      ['Bash', 'git status --short', false, 1, false],
      ['Read', 'Package.swift', false, 40, true],
    ]);
    expect(toolRowLabel(activity.rows[0])).toEqual({ title: 'Bash', meta: '1 line · 2.4 s · failed' });
    expect(toolRowLabel(activity.rows[1])).toEqual({ title: 'Read', meta: '40 lines' });
    expect(activity.rows[1].resultMessageId).toBe('r2');
  });

  it('treats event-kind records as dividers whatever their role', () => {
    const items = buildTranscript([
      message('e1', ChatRole.User, 'Stopped', { kind: ChatMessageKind.Event }),
    ]);
    expect(items.map((item) => item.kind)).toEqual(['event']);
  });

  it('keeps output that names an unknown call as its own row', () => {
    const items = buildTranscript([
      message('r9', ChatRole.Tool, 'late output', { kind: ChatMessageKind.ToolResult, toolName: 'Bash', toolCallId: 'toolu_9' }),
    ]);
    const activity = items[0];
    if (activity.kind !== 'activity') throw new Error('expected activity');
    expect(activity.rows[0]).toMatchObject({ toolName: 'Bash', pending: false, lineCount: 1, toolCallId: 'toolu_9' });
  });
});

describe('polish helpers', () => {
  it('sums a block\'s time once every row finished', () => {
    const base = { id: 'r', toolName: 'Bash', title: '', output: '', detail: '', atUnixMs: T0, redacted: false, truncated: false, isError: false, lineCount: 1, pending: false };
    expect(activitySummary([{ ...base, durationMs: 20_000 }, { ...base, id: 'r2', durationMs: 21_400 }])).toBe('2 tool calls · 41 s');
    expect(activitySummary([{ ...base, durationMs: 300 }])).toBe('1 tool call');
    expect(activitySummary([{ ...base, durationMs: 300 }, { ...base, id: 'r2', durationMs: 0, pending: true }])).toBe('2 tool calls · running');
  });

  it('formats a running row\'s elapsed time', () => {
    expect(formatElapsed(12_400)).toBe('12 s');
    expect(formatElapsed(3 * 60_000 + 5_000)).toBe('3 min');
    expect(formatElapsed(2 * 3_600_000)).toBe('');
    expect(formatElapsed(-5)).toBe('');
  });

  it('strips terminal colour sequences', () => {
    expect(stripAnsi('\u001b[32mok\u001b[0m 12 tests \u001b[1;31mfailed\u001b[m')).toBe('ok 12 tests failed');
    expect(stripAnsi('\u001b]0;title\u0007plain')).toBe('plain');
    expect(stripAnsi('no codes')).toBe('no codes');
  });

  it('recognises unified diffs and classifies their lines', () => {
    const diff = 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n-old\n+new\n same';
    expect(looksLikeDiff(diff)).toBe(true);
    expect(looksLikeDiff('-1\n+2')).toBe(false);
    expect(diff.split('\n').map(diffLineKind)).toEqual(['meta', 'meta', 'meta', 'hunk', 'del', 'add', 'ctx']);
  });

  it('follows new messages only near the bottom', () => {
    expect(shouldAutoScroll(0)).toBe(true);
    expect(shouldAutoScroll(120)).toBe(true);
    expect(shouldAutoScroll(400)).toBe(false);
  });
});
