import { useCallback, useMemo, useState, type ReactNode } from 'react';
import ReactMarkdown, { type Components } from 'react-markdown';
import remarkGfm from 'remark-gfm';
import type { AgentChatMessage } from '@glasstunnel/protocol';
import { formatMessageTimestamp } from './messageTimestamp';
import {
  activitySummary,
  buildTranscript,
  foldUserPrompt,
  readStoredDensity,
  toolRowLabel,
  writeStoredDensity,
  type ToolRow,
  type TranscriptDensity,
  type TranscriptItem,
} from './transcript';

interface Props {
  messages: AgentChatMessage[];
}

/**
 * Chat-style transcript: prose in the sans face, tool activity folded into
 * one-line rows with their output on request, events as dividers, and one
 * time stamp per cluster. "Focus" hides tool output until a row is opened;
 * "Full" keeps every output open.
 */
export function TranscriptView({ messages }: Props) {
  const items = useMemo(() => buildTranscript(messages), [messages]);
  const [density, setDensity] = useTranscriptDensity();
  const firstActivityId = items.find((item) => item.kind === 'activity')?.id;

  return (
    <div className="gt-transcript flex flex-col gap-1.5">
      {items.map((item) => (
        <TranscriptRow
          key={item.id}
          item={item}
          density={density}
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
  density,
  toggle,
}: {
  item: TranscriptItem;
  density: TranscriptDensity;
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
      return <ActivityBlock rows={item.rows} density={density} toggle={toggle} />;
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

const markdownComponents: Components = {
  a: ({ href, children }) => (
    <a href={href} target="_blank" rel="noopener noreferrer">
      {children}
    </a>
  ),
  // Never fetch remote images on the phone; show what the image stood for.
  img: ({ alt }) => <span className="gt-dim">[{alt || 'image'}]</span>,
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
  density,
  toggle,
}: {
  rows: ToolRow[];
  density: TranscriptDensity;
  toggle: ReactNode;
}) {
  return (
    <div className="overflow-hidden rounded-[9px] border border-[color:var(--gt-border)] bg-surface-1">
      <div className="gt-dim flex min-h-[26px] items-center justify-between gap-2 border-b border-[color:var(--gt-border)] px-2.5 py-0.5 text-[11px]">
        <span>{activitySummary(rows)}</span>
        {toggle}
      </div>
      {rows.map((row) => (
        <ToolRowView key={row.id} row={row} open={density === 'full'} />
      ))}
    </div>
  );
}

function ToolRowView({ row, open }: { row: ToolRow; open: boolean }) {
  const label = toolRowLabel(row);
  const hasOutput = row.output.trim().length > 0;
  const summary = (
    <div className="grid grid-cols-[14px_minmax(0,1fr)_auto] items-center gap-2 px-2.5 py-1 text-[12.5px]">
      <span className="gt-tool-caret text-accent" aria-hidden="true">
        {hasOutput ? '▸' : '·'}
      </span>
      <span className="min-w-0 truncate">
        <span className="font-semibold">{label.title}</span>
        {row.detail && <span className="gt-muted ml-1.5 font-mono text-[11.5px]">{row.detail}</span>}
      </span>
      <span className={`shrink-0 text-[11px] tabular-nums ${row.pending ? 'text-warn' : 'gt-dim'}`}>
        {row.pending ? 'running…' : label.meta}
      </span>
    </div>
  );
  if (!hasOutput) {
    return <div className="border-b border-[color:var(--gt-border)] last:border-b-0">{summary}</div>;
  }
  return (
    <details key={open ? 'open' : 'closed'} open={open} className="gt-tool-row border-b border-[color:var(--gt-border)] last:border-b-0">
      <summary className="cursor-pointer list-none [&::-webkit-details-marker]:hidden">{summary}</summary>
      <ToolOutput row={row} />
    </details>
  );
}

function ToolOutput({ row }: { row: ToolRow }) {
  return (
    <div className="px-2 pb-1.5 pl-[26px]">
      <pre className="gt-tool-output">{row.output.replace(/\s+$/, '')}</pre>
      {row.redacted && <RedactedPill reasons={row.redactionReasons} />}
    </div>
  );
}

function RedactedPill({ reasons }: { reasons?: string[] }): ReactNode {
  const named = reasons && reasons.length > 0;
  return (
    <span
      className="mt-1 inline-flex items-center gap-1 rounded-full bg-warn/15 px-1.5 py-0.5 text-[10px] text-warn"
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
