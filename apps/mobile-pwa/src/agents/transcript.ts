import { ChatMessageKind, ChatRole, type AgentChatMessage } from '@glasstunnel/protocol';

/**
 * Turns the flat list of transcript messages a Mac sends into the items the
 * phone actually renders: prose, folded tool activity, events, and time
 * stamps. The Mac still sends plain text per record; this is where tool
 * calls stop being walls of text.
 */

export type TranscriptDensity = 'focus' | 'full';

export interface ToolRow {
  id: string;
  /** Tool name from the pending call, or '' for output with no known call. */
  toolName: string;
  /** One-line label from the Mac (a command, a file name, a pattern), or ''. */
  title: string;
  /** Output text as carried by the snapshot: the full text, or a preview when `truncated`. */
  output: string;
  /** First meaningful line of the output, trimmed for a one-line row. */
  detail: string;
  lineCount: number;
  pending: boolean;
  atUnixMs: number;
  redacted: boolean;
  redactionReasons?: string[];
  /** Id of the result message, for fetching the full text when `truncated`. */
  resultMessageId?: string;
  truncated: boolean;
  durationMs: number;
  isError: boolean;
  /** Id shared by the call and its result when the Mac sends structured rows. */
  toolCallId?: string;
}

export type TranscriptItem =
  | { kind: 'stamp'; id: string; atUnixMs: number }
  | { kind: 'user'; id: string; message: AgentChatMessage }
  | { kind: 'assistant'; id: string; message: AgentChatMessage }
  | { kind: 'event'; id: string; message: AgentChatMessage }
  | { kind: 'activity'; id: string; rows: ToolRow[]; atUnixMs: number };

/** A new time stamp is shown when this much time passed since the last one. */
export const STAMP_GAP_MS = 10 * 60 * 1000;
export const USER_PROMPT_FOLD_LINES = 6;
export const TOOL_DETAIL_MAX_CHARS = 96;

export function buildTranscript(messages: AgentChatMessage[]): TranscriptItem[] {
  const items: TranscriptItem[] = [];
  let lastStampAt = Number.NEGATIVE_INFINITY;

  const stampIfNeeded = (message: AgentChatMessage) => {
    if (!Number.isFinite(message.atUnixMs) || message.atUnixMs <= 0) return;
    if (message.atUnixMs - lastStampAt < STAMP_GAP_MS) return;
    lastStampAt = message.atUnixMs;
    items.push({ kind: 'stamp', id: `stamp-${message.messageId}`, atUnixMs: message.atUnixMs });
  };

  const currentActivity = (): Extract<TranscriptItem, { kind: 'activity' }> | null => {
    const last = items[items.length - 1];
    return last && last.kind === 'activity' ? last : null;
  };

  const openActivity = (message: AgentChatMessage) => {
    const existing = currentActivity();
    if (existing) return existing;
    const created: Extract<TranscriptItem, { kind: 'activity' }> = {
      kind: 'activity',
      id: `activity-${message.messageId}`,
      rows: [],
      atUnixMs: message.atUnixMs,
    };
    items.push(created);
    return created;
  };

  const addCalls = (message: AgentChatMessage) => {
    const activity = openActivity(message);
    for (const call of message.pendingToolCalls) {
      activity.rows.push({
        id: `${message.messageId}-${call.toolCallId}`,
        toolName: message.toolName || call.toolName,
        title: message.title ?? '',
        output: '',
        detail: '',
        lineCount: 0,
        pending: true,
        atUnixMs: message.atUnixMs,
        redacted: false,
        truncated: false,
        durationMs: 0,
        isError: false,
        toolCallId: message.toolCallId || call.toolCallId,
      });
    }
  };

  const addResult = (message: AgentChatMessage) => {
    const activity = openActivity(message);
    // A structured result names its call; older Macs leave pairing to order.
    const target = message.toolCallId
      ? findPendingRow(items, message.toolCallId)
      : activity.rows.find((row) => row.pending);
    const output = message.text;
    const filled: Partial<ToolRow> = {
      output,
      detail: firstMeaningfulLine(output),
      lineCount: message.outputLineCount || countLines(output),
      pending: false,
      redacted: message.redacted,
      redactionReasons: message.redactionReasons,
      resultMessageId: message.messageId,
      truncated: message.truncated === true,
      durationMs: message.durationMs ?? 0,
      isError: message.isError === true,
    };
    if (target) {
      Object.assign(target, filled);
      if (!target.toolName && message.toolName) target.toolName = message.toolName;
      return;
    }
    activity.rows.push({
      id: `${message.messageId}-output`,
      toolName: message.toolName ?? '',
      title: '',
      atUnixMs: message.atUnixMs,
      output,
      detail: filled.detail ?? '',
      lineCount: filled.lineCount ?? 0,
      pending: false,
      redacted: message.redacted,
      redactionReasons: message.redactionReasons,
      resultMessageId: message.messageId,
      truncated: filled.truncated ?? false,
      durationMs: filled.durationMs ?? 0,
      isError: filled.isError ?? false,
      toolCallId: message.toolCallId,
    });
  };

  for (const message of messages) {
    const hasCalls = message.pendingToolCalls.length > 0;
    if (message.kind === ChatMessageKind.Event) {
      items.push({ kind: 'event', id: message.messageId, message });
      continue;
    }
    switch (message.role) {
      case ChatRole.Tool:
        if (hasCalls || message.kind === ChatMessageKind.ToolCall) {
          stampIfNeeded(message);
          addCalls(message);
        } else {
          addResult(message);
        }
        break;
      case ChatRole.System:
        items.push({ kind: 'event', id: message.messageId, message });
        break;
      case ChatRole.User:
        stampIfNeeded(message);
        items.push({ kind: 'user', id: message.messageId, message });
        break;
      default: {
        stampIfNeeded(message);
        const text = message.text.trim();
        if (text.length > 0) {
          items.push({ kind: 'assistant', id: message.messageId, message });
        }
        if (hasCalls) addCalls(message);
      }
    }
  }
  return items;
}

/** One-line label for a tool row: the tool's name and, once it ran, its size and time. */
export function toolRowLabel(row: ToolRow): { title: string; meta: string } {
  const title = row.toolName || 'Output';
  if (row.pending) return { title, meta: 'running' };
  const size = row.lineCount === 0 ? 'no output' : row.lineCount === 1 ? '1 line' : `${row.lineCount} lines`;
  const parts = [size];
  if (row.durationMs >= 1000) parts.push(`${formatSeconds(row.durationMs)} s`);
  if (row.isError) parts.push('failed');
  return { title, meta: parts.join(' · ') };
}

export function formatSeconds(durationMs: number): string {
  const seconds = durationMs / 1000;
  return seconds >= 10 ? String(Math.round(seconds)) : seconds.toFixed(1);
}

/** The most recent still-pending row with this call id, in any activity block. */
function findPendingRow(items: TranscriptItem[], toolCallId: string): ToolRow | undefined {
  for (let index = items.length - 1; index >= 0; index -= 1) {
    const item = items[index];
    if (item.kind !== 'activity') continue;
    const row = item.rows.find((candidate) => candidate.pending && candidate.toolCallId === toolCallId);
    if (row) return row;
  }
  return undefined;
}

export function activitySummary(rows: ToolRow[]): string {
  const calls = rows.filter((row) => row.toolName).length || rows.length;
  const pending = rows.some((row) => row.pending);
  const label = calls === 1 ? '1 tool call' : `${calls} tool calls`;
  return pending ? `${label} · running` : label;
}

/** Folds a long prompt so a pasted wall of text does not push the reply away. */
export function foldUserPrompt(
  text: string,
  maxLines = USER_PROMPT_FOLD_LINES,
): { shown: string; hiddenLines: number } {
  const lines = text.split('\n');
  if (lines.length <= maxLines) return { shown: text, hiddenLines: 0 };
  return { shown: lines.slice(0, maxLines).join('\n'), hiddenLines: lines.length - maxLines };
}

export function countLines(text: string): number {
  const trimmed = text.replace(/\s+$/, '');
  if (trimmed.length === 0) return 0;
  return trimmed.split('\n').length;
}

export function firstMeaningfulLine(text: string): string {
  const line = text
    .split('\n')
    .map((candidate) => candidate.trim())
    .find((candidate) => candidate.length > 0);
  if (!line) return '';
  return line.length > TOOL_DETAIL_MAX_CHARS ? `${line.slice(0, TOOL_DETAIL_MAX_CHARS - 1)}…` : line;
}

const DENSITY_STORAGE_KEY = 'gt.transcript.density';

export function readStoredDensity(storage: Pick<Storage, 'getItem'> | null): TranscriptDensity {
  try {
    const value = storage?.getItem(DENSITY_STORAGE_KEY);
    return value === 'full' ? 'full' : 'focus';
  } catch {
    return 'focus';
  }
}

export function writeStoredDensity(
  storage: Pick<Storage, 'setItem'> | null,
  density: TranscriptDensity,
): void {
  try {
    storage?.setItem(DENSITY_STORAGE_KEY, density);
  } catch {
    // Private browsing or blocked storage: the choice just does not persist.
  }
}
