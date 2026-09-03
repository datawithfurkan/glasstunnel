import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import ReactMarkdown, { type Components } from 'react-markdown';
import remarkGfm from 'remark-gfm';
import type { AgentChatMessage } from '@glasstunnel/protocol';
import { useAppStore } from '../lib/store';
import { formatMessageTimestamp } from './messageTimestamp';
import {
  activitySummary,
  buildTranscript,
  diffLineKind,
  foldUserPrompt,
  formatElapsed,
  looksLikeDiff,
  readStoredDensity,
  stripAnsi,
  toolRowLabel,
  writeStoredDensity,
  type ToolRow,
  type TranscriptDensity,
  type TranscriptItem,
} from './transcript';

interface Props {
  agentId: string;
  messages: AgentChatMessage[];
}

/**
 * Chat-style transcript: prose in the sans face, tool activity folded into
 * one-line rows with their output on request, events as dividers, and one
 * time stamp per cluster. "Focus" hides tool output until a row is opened;
 * "Full" keeps every output open.
 */
export function TranscriptView({ agentId, messages }: Props) {
  const items = useMemo(() => buildTranscript(messages), [messages]);
  const [density, setDensity] = useTranscriptDensity();
  const firstActivityId = items.find((item) => item.kind === 'activity')?.id;
  const anyPending = items.some((item) => item.kind === 'activity' && item.rows.some((row) => row.pending));
  const now = useNow(anyPending);

  return (
    <div className="gt-transcript flex flex-col gap-1.5">
      {items.map((item) => (
        <TranscriptRow
          key={item.id}
          item={item}
          agentId={agentId}
          density={density}
          now={now}
          toggle={item.id === firstActivityId ? <DensityToggle density={density} onChange={setDensity} /> : null}
        />
      ))}
    </div>
  );
}

function useTranscriptDensity(): [TranscriptDensity, (density: TranscriptDensity) => void] {
  const [density, setDensityState] = useState<TranscriptDensity>(() =>
    readStoredDensity(typeof window === 'undefined' ? null : window.localStorage),
  );
  const setDensity = useCallback((next: TranscriptDensity) => {
    setDensityState(next);
    writeStoredDensity(typeof window === 'undefined' ? null : window.localStorage, next);
  }, []);
  return [density, setDensity];
}

/** A once-a-second clock, ticking only while something is running. */
function useNow(active: boolean): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!active) return;
    setNow(Date.now());
    const id = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(id);
  }, [active]);
  return now;
}

function DensityToggle({
  density,
  onChange,
}: {
  density: TranscriptDensity;
  onChange: (density: TranscriptDensity) => void;
}) {
  return (
    <div
      role="radiogroup"
      aria-label="Transcript detail"
      className="inline-flex overflow-hidden rounded-full border border-[color:var(--gt-border)] text-[10.5px] leading-none"
    >
      {(['focus', 'full'] as const).map((option) => (
        <button
          key={option}
          type="button"
          role="radio"
          aria-checked={density === option}
          onClick={() => onChange(option)}
          className={`px-2 py-1 capitalize transition ${
            density === option ? 'bg-surface-3 text-[color:var(--gt-text)]' : 'gt-muted hover:text-[color:var(--gt-text)]'
          }`}
        >
          {option}
        </button>
      ))}
    </div>
  );
}

function TranscriptRow({
  item,
  agentId,
  density,
  now,
  toggle,
}: {
  item: TranscriptItem;
  agentId: string;
  density: TranscriptDensity;
  now: number;
  toggle: ReactNode;
}) {
  switch (item.kind) {
    case 'stamp':
      return <TimeStamp atUnixMs={item.atUnixMs} />;
    case 'user':
      return <UserPrompt message={item.message} />;
    case 'assistant':
      return <AssistantText message={item.message} />;
    case 'event':
      return <EventDivider message={item.message} />;
    case 'activity':
      return <ActivityBlock rows={item.rows} agentId={agentId} density={density} now={now} toggle={toggle} />;
    default:
      return null;
  }
}

function TimeStamp({ atUnixMs }: { atUnixMs: number }) {
  const timestamp = formatMessageTimestamp(atUnixMs);
  if (!timestamp) return null;
  return (
    <div className="gt-dim text-center text-[10.5px] tabular-nums" aria-label={`Around ${timestamp.full}`}>
      <time dateTime={timestamp.iso} title={timestamp.full}>
        {timestamp.label}
      </time>
    </div>
  );
}

function UserPrompt({ message }: { message: AgentChatMessage }) {
  const [expanded, setExpanded] = useState(false);
  const folded = foldUserPrompt(message.text);
  const showAll = expanded || folded.hiddenLines === 0;
  return (
    <div className="flex justify-end">
      <div className="max-w-[88%] rounded-[12px] rounded-br-[3px] border border-ok/25 bg-ok/12 px-2.5 py-1.5 text-[14.5px] leading-[1.4] text-[color:var(--gt-text)]">
        <div className="whitespace-pre-wrap break-words">{showAll ? message.text : folded.shown}</div>
        {!showAll && (
          <button
            type="button"
            onClick={() => setExpanded(true)}
            className="mt-1 text-[12px] text-accent"
          >
            Show {folded.hiddenLines} more {folded.hiddenLines === 1 ? 'line' : 'lines'}
          </button>
        )}
        {message.redacted && <RedactedPill reasons={message.redactionReasons} />}
      </div>
    </div>
  );
}

/** A fenced code block with a copy button, reading the rendered text on tap. */
function MarkdownPre({ children }: { children?: ReactNode }) {
  const ref = useRef<HTMLPreElement>(null);
  return (
    <div className="gt-md-pre">
      <pre ref={ref}>{children}</pre>
      <div className="gt-md-pre-actions">
        <CopyButton getText={() => ref.current?.innerText ?? ''} />
      </div>
    </div>
  );
}

const markdownComponents: Components = {
  a: ({ href, children }) => (
    <a href={href} target="_blank" rel="noopener noreferrer">
      {children}
    </a>
  ),
  // Never fetch remote images on the phone; show what the image stood for.
  img: ({ alt }) => <span className="gt-dim">[{alt || 'image'}]</span>,
  pre: ({ children }) => <MarkdownPre>{children}</MarkdownPre>,
};

function AssistantText({ message }: { message: AgentChatMessage }) {
  return (
    <div className="px-0.5">
      <div className="gt-md">
        <ReactMarkdown remarkPlugins={[remarkGfm]} components={markdownComponents}>
          {message.text}
        </ReactMarkdown>
      </div>
      {message.redacted && <RedactedPill reasons={message.redactionReasons} />}
    </div>
  );
}

function EventDivider({ message }: { message: AgentChatMessage }) {
  const [firstLine, ...rest] = message.text.split('\n');
  const timestamp = formatMessageTimestamp(message.atUnixMs);
  return (
    <div className="gt-dim flex items-center gap-2 text-[11px]" role="status">
      <span className="h-px flex-1 bg-[color:var(--gt-border)]" aria-hidden="true" />
      <span className="max-w-[80%] truncate" title={rest.length > 0 ? message.text : undefined}>
        {firstLine}
        {timestamp ? ` · ${timestamp.label}` : ''}
      </span>
      <span className="h-px flex-1 bg-[color:var(--gt-border)]" aria-hidden="true" />
    </div>
  );
}

function ActivityBlock({
  rows,
  agentId,
  density,
  now,
  toggle,
}: {
  rows: ToolRow[];
  agentId: string;
  density: TranscriptDensity;
  now: number;
  toggle: ReactNode;
}) {
  return (
    <div className="overflow-hidden rounded-[9px] border border-[color:var(--gt-border)] bg-surface-1">
      <div className="gt-dim flex min-h-[26px] items-center justify-between gap-2 border-b border-[color:var(--gt-border)] px-2.5 py-0.5 text-[11px]">
        <span className="tabular-nums">{activitySummary(rows)}</span>
        {toggle}
      </div>
      {rows.map((row) => (
        <ToolRowView key={row.id} row={row} agentId={agentId} now={now} open={density === 'full'} />
      ))}
    </div>
  );
}

function ToolRowView({ row, agentId, now, open }: { row: ToolRow; agentId: string; now: number; open: boolean }) {
  const label = toolRowLabel(row);
  const hasOutput = row.output.trim().length > 0;
  // A title from the Mac (the command, the file) beats the first output line.
  const detail = row.title || row.detail;
  const elapsed = row.pending ? formatElapsed(now - row.atUnixMs) : '';
  const summary = (
    <div className="grid grid-cols-[14px_minmax(0,1fr)_auto] items-center gap-2 px-2.5 py-1 text-[12.5px]">
      <span className={`gt-tool-caret ${row.isError ? 'text-err' : 'text-accent'}`} aria-hidden="true">
        {hasOutput ? '▸' : '·'}
      </span>
      <span className="min-w-0 truncate">
        <span className="font-semibold">{label.title}</span>
        {detail && <span className="gt-muted ml-1.5 font-mono text-[11.5px]">{detail}</span>}
      </span>
      <span className={`shrink-0 text-[11px] tabular-nums ${row.pending ? 'text-warn' : row.isError ? 'text-err' : 'gt-dim'}`}>
        {row.pending ? (elapsed ? `running · ${elapsed}` : 'running…') : label.meta}
      </span>
    </div>
  );
  if (!hasOutput) {
    return <div className="border-b border-[color:var(--gt-border)] last:border-b-0">{summary}</div>;
  }
  return (
    <details key={open ? 'open' : 'closed'} open={open} className="gt-tool-row border-b border-[color:var(--gt-border)] last:border-b-0">
      <summary className="cursor-pointer list-none [&::-webkit-details-marker]:hidden">{summary}</summary>
      <ToolOutput row={row} agentId={agentId} />
    </details>
  );
}

function ToolOutput({ row, agentId }: { row: ToolRow; agentId: string }) {
  const detail = useAppStore((s) => (row.resultMessageId ? s.messageDetails[row.resultMessageId] : undefined));
  const requestMessageDetail = useAppStore((s) => s.requestMessageDetail);
  const [requested, setRequested] = useState(false);
  const text = stripAnsi(detail?.text ?? row.output).replace(/\s+$/, '');
  const canFetch = row.truncated && !detail && Boolean(row.resultMessageId);
  return (
    <div className="px-2 pb-1.5 pl-[26px]">
      <pre className="gt-tool-output">{looksLikeDiff(text) ? <DiffLines text={text} /> : text}</pre>
      <div className="mt-1 flex items-center gap-3 text-[12px]">
        <CopyButton getText={() => text} />
        {canFetch && (
          <button
            type="button"
            onClick={() => {
              if (row.resultMessageId && requestMessageDetail(agentId, row.resultMessageId)) setRequested(true);
            }}
            className="text-accent disabled:opacity-60"
            disabled={requested}
          >
            {requested ? 'Loading…' : `Show all ${row.lineCount} lines`}
          </button>
        )}
        {detail?.truncated && <span className="gt-dim text-[11px]">cut at the Mac's limit</span>}
        {(row.redacted || detail?.redacted) && <RedactedPill reasons={detail?.redactionReasons ?? row.redactionReasons} />}
      </div>
    </div>
  );
}

/** Unified-diff lines coloured by kind; the text itself is unchanged. */
function DiffLines({ text }: { text: string }) {
  const lines = text.split('\n');
  return (
    <>
      {lines.map((line, index) => (
        <span key={index} className={`gt-diff-${diffLineKind(line)}`}>
          {line}
          {index < lines.length - 1 ? '\n' : ''}
        </span>
      ))}
    </>
  );
}

function CopyButton({ getText }: { getText: () => string }) {
  const [copied, setCopied] = useState(false);
  const clipboard = typeof navigator !== 'undefined' ? navigator.clipboard : undefined;
  useEffect(() => {
    if (!copied) return;
    const id = window.setTimeout(() => setCopied(false), 1500);
    return () => window.clearTimeout(id);
  }, [copied]);
  if (!clipboard) return null;
  return (
    <button
      type="button"
      className="gt-copy"
      aria-label="Copy"
      onClick={() => {
        clipboard.writeText(getText()).then(
          () => setCopied(true),
          () => setCopied(false),
        );
      }}
    >
      {copied ? 'Copied' : 'Copy'}
    </button>
  );
}

function RedactedPill({ reasons }: { reasons?: string[] }): ReactNode {
  const named = reasons && reasons.length > 0;
  return (
    <span
      className="inline-flex items-center gap-1 rounded-full bg-warn/15 px-1.5 py-0.5 text-[10px] text-warn"
      title={named ? `Redacted patterns: ${reasons.join(', ')}` : 'Sensitive data redacted by the Mac before it left your machine'}
    >
      redacted
      {named && (
        <span className="opacity-80">
          {reasons.slice(0, 2).join(', ')}
          {reasons.length > 2 ? '…' : ''}
        </span>
      )}
    </span>
  );
}
