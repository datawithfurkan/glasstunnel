import { useEffect, useRef, useState, type ReactNode, type RefObject } from 'react';
import type {
  AgentChatMessage,
  AgentInputRequest,
  AgentInputRequestAnswer,
  AgentRuntimeControls,
  AgentRuntimeSettingsUpdate,
  AgentStateSnapshot,
  AgentTargetOption,
  RemoteApp,
} from '@glasstunnel/protocol';
import { AdapterKind, AgentStatus, ChatRole, QuickReplyKind } from '@glasstunnel/protocol';
import {
  codexPromptDeliveryUnavailable,
  cursorPromptDeliveryUnavailable,
  statusColor,
  useAppStore,
} from '../lib/store';
import { createClientId } from '../lib/id';
import { HorizontalScrollStrip } from '../ui/HorizontalScrollStrip';
import { VideoTile } from './VideoTile';
import { TranscriptView } from './TranscriptView';
import { formatMessageTimestamp } from './messageTimestamp';
import { shouldAutoScroll } from './transcript';

interface Props {
  app: RemoteApp;
  snapshot?: AgentStateSnapshot;
  showTargetSwitcher?: boolean;
  onBack?: () => void;
  titleOverride?: string;
  subtitleOverride?: string;
  hostOnline?: boolean | null;
  connectionError?: string | null;
  headerAction?: ReactNode;
  onSelectTarget?: (target: AgentTargetOption) => void;
  compactChrome?: boolean;
}

const quickReplies: { label: string; kind: QuickReplyKind }[] = [
  { label: 'Continue', kind: QuickReplyKind.Continue },
  { label: 'Try again', kind: QuickReplyKind.TryAgain },
  { label: 'Explain', kind: QuickReplyKind.Explain },
  { label: 'Commit', kind: QuickReplyKind.Commit },
  { label: 'Stop', kind: QuickReplyKind.Stop },
];

export function terminalControlNotice(): string {
  return 'Runs on your Mac. Review commands before running.';
}

export function cliControlNotice(): string {
  return 'Runs on your Mac. Review prompts before sending.';
}

export function cursorAgentControlNotice(): string {
  return 'Ask mode only. File edits are not enabled.';
}

export function commandSurfaceNotice(app: RemoteApp): string {
  if (isTerminalApp(app)) return terminalControlNotice();
  if (app.adapterKind === AdapterKind.CursorAgent || app.remoteAppId === 'cursor-agent') return cursorAgentControlNotice();
  return cliControlNotice();
}

export function commandSurfacePromptPlaceholder(app: RemoteApp): string {
  return isTerminalApp(app) ? 'Type a terminal command...' : 'Send a prompt...';
}

export function commandSurfaceSupportsAttachments(app: RemoteApp): boolean {
  return app.adapterKind !== AdapterKind.CursorAgent && app.remoteAppId !== 'cursor-agent';
}

export function terminalLoadingText(appName: string): string {
  return `opening ${appName.toLowerCase()} session...`;
}

export function terminalEmptyText(): string {
  return 'waiting for terminal output';
}

export function selectedTerminalSessionLabel(snapshot?: AgentStateSnapshot): string | null {
  const target = snapshot?.availableTargets?.find((candidate) => candidate.selected) ?? snapshot?.availableTargets?.[0];
  if (!target || target.targetKind !== 'session') {
    return null;
  }
  return target.threadLabel || target.label || null;
}

export function terminalStatusLabel(status: AgentStatus, waitingForSnapshot: boolean, hostUnavailable = false): string {
  if (hostUnavailable) return 'offline';
  if (waitingForSnapshot) return 'syncing';
  switch (status) {
    case AgentStatus.Idle:
    case AgentStatus.Done:
      return 'ready';
    case AgentStatus.Working:
      return 'running';
    case AgentStatus.WaitingInput:
    case AgentStatus.AwaitingApproval:
      return 'waiting';
    case AgentStatus.Error:
      return 'error';
    case AgentStatus.Disconnected:
      return 'offline';
    default:
      return 'unknown';
  }
}

export function agentInteractionUnavailable(
  status: AgentStatus,
  waitingForSnapshot: boolean,
  hostUnavailable = false,
): boolean {
  return hostUnavailable || waitingForSnapshot || status === AgentStatus.Disconnected || status === AgentStatus.Error;
}

export function runtimeControlsUnavailable(
  status: AgentStatus,
  waitingForSnapshot: boolean,
  hostUnavailable = false,
  statusDetail?: string | null,
): boolean {
  if (agentInteractionUnavailable(status, waitingForSnapshot, hostUnavailable)) return true;
  if (status !== AgentStatus.Working) return false;

  const detail = (statusDetail ?? '').trim().toLowerCase();
  return detail !== 'settings updated';
}

export function terminalSwitchingSession(status: AgentStatus, statusDetail?: string | null): boolean {
  return status === AgentStatus.Working && /^(opening|switching)\s+/i.test(statusDetail ?? '');
}

export function commandSurfaceInteractionUnavailable(
  status: AgentStatus,
  waitingForSnapshot: boolean,
  hostUnavailable: boolean,
  switchingTarget: boolean,
  allowWorkingInput = false,
): boolean {
  return agentInteractionUnavailable(status, waitingForSnapshot, hostUnavailable) ||
    switchingTarget ||
    (status === AgentStatus.Working && !allowWorkingInput);
}

export function cursorTargetInteractionUnavailable(
  snapshot?: Pick<AgentStateSnapshot, 'adapterKind' | 'status' | 'statusDetail' | 'availableTargets'>,
): boolean {
  return cursorPromptDeliveryUnavailable(snapshot);
}

export function codexTargetInteractionUnavailable(
  snapshot?: Pick<AgentStateSnapshot, 'adapterKind' | 'availableTargets'>,
): boolean {
  return codexPromptDeliveryUnavailable(snapshot);
}

export function terminalTargetButtonState(
  target: Pick<AgentTargetOption, 'label'> &
    Partial<Pick<AgentTargetOption, 'selected' | 'threadLabel' | 'projectLabel' | 'subtitle' | 'targetKind'>>,
  readOnly: boolean,
): {
  ariaDisabled: boolean;
  ariaLabel: string;
  ariaPressed: boolean;
  canSelect: boolean;
} {
  return commandTargetButtonState(target, readOnly, AdapterKind.Terminal);
}

export function commandTargetButtonState(
  target: Pick<AgentTargetOption, 'label'> &
    Partial<Pick<AgentTargetOption, 'selected' | 'threadLabel' | 'projectLabel' | 'subtitle' | 'targetKind' | 'isActive'>>,
  readOnly: boolean,
  adapterKind?: AdapterKind,
): {
  ariaDisabled: boolean;
  ariaLabel: string;
  ariaPressed: boolean;
  canSelect: boolean;
} {
  const selected = Boolean(target.selected);
  const unverifiedCodexSelection =
    adapterKind === AdapterKind.Mirror && selected && target.isActive === false;
  const ariaDisabled = (selected && !unverifiedCodexSelection) || readOnly;
  const display = commandTargetButtonDisplay(target, adapterKind);
  const cursorCurrent = cursorTargetIsCurrent(target);
  const ariaLabel =
    adapterKind === AdapterKind.Cursor
      ? cursorCurrent
        ? `Current chat: ${display.label}`
        : selected
          ? `Browsing chat: ${display.label}`
          : `Browse chat: ${display.label}`
      : unverifiedCodexSelection
        ? `Open chat: ${display.label}`
        : selected
          ? `Current session: ${display.label}`
          : `Switch to ${display.label}`;

  return {
    ariaDisabled,
    ariaLabel,
    ariaPressed: selected,
    canSelect: !ariaDisabled,
  };
}

export function commandTargetButtonDisplay(
  target: Pick<AgentTargetOption, 'label'> &
    Partial<Pick<AgentTargetOption, 'selected' | 'threadLabel' | 'projectLabel' | 'subtitle' | 'targetKind' | 'isActive'>>,
  adapterKind?: AdapterKind,
): { label: string; subtitle: string } {
  const label = (
    target.targetKind === 'thread'
      ? target.threadLabel || target.label
      : target.label || target.threadLabel
  )?.trim() || 'Current session';
  const subtitle = (
    target.targetKind === 'thread'
      ? target.projectLabel || target.subtitle
      : target.subtitle || target.projectLabel
  )?.trim() || '';

  if (adapterKind === AdapterKind.Cursor) {
    return {
      label,
      subtitle: cursorTargetIsCurrent(target) ? 'Current chat' : 'Browse only',
    };
  }

  if (adapterKind === AdapterKind.Mirror && target.selected && target.isActive === false) {
    return { label, subtitle: 'Open this chat' };
  }

  return {
    label,
    subtitle: subtitle === label ? '' : subtitle,
  };
}

function cursorTargetIsCurrent(
  target: Partial<Pick<AgentTargetOption, 'selected' | 'isActive'>>,
): boolean {
  return Boolean(target.isActive === true || (target.selected && target.isActive !== false));
}

const MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024;
const MAX_ATTACHMENT_BATCH_BYTES = 100 * 1024 * 1024;
const MAX_ATTACHMENTS = 20;

interface PendingAttachment {
  id: string;
  file: File;
  previewUrl: string | null;
}

export function AgentCard({
  app,
  snapshot,
  showTargetSwitcher = true,
  onBack,
  titleOverride,
  subtitleOverride,
  hostOnline = true,
  connectionError = null,
  headerAction,
  onSelectTarget,
  compactChrome = false,
}: Props) {
  const sendText = useAppStore((s) => s.sendText);
  const sendInputRequestResponse = useAppStore((s) => s.sendInputRequestResponse);
  const sendFileAttachmentBatch = useAppStore((s) => s.sendFileAttachmentBatch);
  const sendQuick = useAppStore((s) => s.sendQuickReply);
  const sendInterrupt = useAppStore((s) => s.sendInterrupt);
  const selectTarget = useAppStore((s) => s.selectTarget);
  const updateRuntimeSettings = useAppStore((s) => s.updateRuntimeSettings);
  const videoStreams = useAppStore((s) => s.videoStreams);
  const readOnly = useAppStore((s) => s.readOnlyMode);
  const pairedHostDeviceId = useAppStore((s) => s.pairedHost?.deviceId ?? null);

  const [prompt, setPrompt] = useState('');
  const [expanded, setExpanded] = useState(false);
  const [actionsOpen, setActionsOpen] = useState(false);
  const [attachments, setAttachments] = useState<PendingAttachment[]>([]);
  const [composerError, setComposerError] = useState<string | null>(null);
  const [uploadingAttachments, setUploadingAttachments] = useState(false);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const messageEndRef = useRef<HTMLDivElement>(null);
  const transcriptScrollRef = useRef<HTMLElement>(null);
  /// Whether the reader is at the end of the transcript; new messages only
  /// pull the view along while this holds, otherwise a chip offers the jump.
  const followingRef = useRef(true);
  const [unseenMessages, setUnseenMessages] = useState(false);
  const attachmentsRef = useRef<PendingAttachment[]>([]);

  const status = snapshot?.status ?? AgentStatus.Working;
  const stream = videoStreams[app.agentId];
  const messages = snapshot?.recentMessages ?? [];
  const targets = snapshot?.availableTargets ?? [];
  const commandSurfaceMode = isCommandSurfaceApp(app);
  const terminalMode = isTerminalApp(app);
  const terminalSessionLabel = terminalMode ? selectedTerminalSessionLabel(snapshot) : null;
  const hostUnavailable = hostOnline === false || Boolean(connectionError);
  const pendingInputRequest = snapshot?.pendingInputRequest;
  const latestMessage = messages[messages.length - 1];
  const hasLatestMessage = Boolean(latestMessage);
  const waitingForSnapshot = !snapshot;
  const loadingContext =
    waitingForSnapshot ||
    (messages.length === 0 &&
      status === AgentStatus.Working &&
      /loading|preparing|waiting/i.test(snapshot?.statusDetail ?? ''));
  const hasAttachments = attachments.length > 0;
  const supportsAttachments = commandSurfaceSupportsAttachments(app);
  const waitingForChoice = Boolean(pendingInputRequest);
  const targetSwitchingContext =
    commandSurfaceMode &&
    terminalSwitchingSession(status, snapshot?.statusDetail);
  const interactionUnavailable =
    commandSurfaceInteractionUnavailable(status, waitingForSnapshot, hostUnavailable, targetSwitchingContext, terminalMode) ||
    cursorTargetInteractionUnavailable(snapshot) ||
    codexTargetInteractionUnavailable(snapshot);
  const composerDisabled =
    readOnly ||
    uploadingAttachments ||
    interactionUnavailable ||
    waitingForChoice;
  const hasDraft = prompt.trim().length > 0;
  const canSubmit = (hasDraft || hasAttachments) && !composerDisabled;
  const showStopButton =
    status === AgentStatus.Working &&
    !loadingContext &&
    !hasDraft &&
    !hasAttachments &&
    !waitingForSnapshot &&
    !readOnly &&
    !uploadingAttachments &&
    !waitingForChoice;
  const mainSurfaceClass = commandSurfaceMode
    ? 'min-w-0 flex-1 min-h-0 overflow-hidden bg-[#0d0d0e] p-2 sm:p-4'
    : 'flex-1 page-scroll px-3 py-2 space-y-2';
  const footerClass = commandSurfaceMode
    ? 'gt-mobile-composer border-t border-[color:var(--gt-border)] bg-[#151312] px-3 pt-2 pb-3'
    : 'gt-mobile-composer border-t border-[color:var(--gt-border)] px-3 pt-2 pb-3';

  useEffect(() => {
    const el = inputRef.current;
    if (!el) return;
    el.style.height = 'auto';
    el.style.height = `${Math.min(160, el.scrollHeight)}px`;
  }, [prompt]);

  useEffect(() => {
    // A different card starts at its end.
    followingRef.current = true;
    setUnseenMessages(false);
  }, [app.agentId]);

  useEffect(() => {
    const target = messageEndRef.current;
    if (!target) return;
    if (!commandSurfaceMode && !followingRef.current) {
      setUnseenMessages(true);
      return;
    }

    const scroll = () => {
      target.scrollIntoView({
        block: 'end',
        behavior: hasLatestMessage ? 'smooth' : 'auto',
      });
    };

    scroll();
    const frame = window.requestAnimationFrame(scroll);
    return () => window.cancelAnimationFrame(frame);
  }, [app.agentId, commandSurfaceMode, hasLatestMessage, latestMessage?.messageId, latestMessage?.text, messages.length]);

  const handleTranscriptScroll = () => {
    const el = transcriptScrollRef.current;
    if (!el) return;
    const distance = el.scrollHeight - el.scrollTop - el.clientHeight;
    followingRef.current = shouldAutoScroll(distance);
    if (followingRef.current) setUnseenMessages(false);
  };

  const jumpToLatest = () => {
    followingRef.current = true;
    setUnseenMessages(false);
    messageEndRef.current?.scrollIntoView({ block: 'end', behavior: 'smooth' });
  };

  useEffect(() => {
    attachmentsRef.current = attachments;
  }, [attachments]);

  useEffect(() => () => {
    revokeAttachmentPreviews(attachmentsRef.current);
  }, []);

  useEffect(() => {
    setPrompt('');
    setComposerError(null);
    setUploadingAttachments(false);
    revokeAttachmentPreviews(attachmentsRef.current);
    attachmentsRef.current = [];
    setAttachments([]);
    if (fileInputRef.current) {
      fileInputRef.current.value = '';
    }
  }, [pairedHostDeviceId, app.agentId]);

  const clearAttachments = () => {
    revokeAttachmentPreviews(attachmentsRef.current);
    attachmentsRef.current = [];
    setAttachments([]);
    if (fileInputRef.current) {
      fileInputRef.current.value = '';
    }
  };

  const removeAttachment = (attachmentId: string) => {
    setComposerError(null);
    setAttachments((current) => {
      const removed = current.find((attachment) => attachment.id === attachmentId);
      if (removed?.previewUrl) {
        URL.revokeObjectURL(removed.previewUrl);
      }
      const next = current.filter((attachment) => attachment.id !== attachmentId);
      attachmentsRef.current = next;
      return next;
    });
    if (fileInputRef.current) {
      fileInputRef.current.value = '';
    }
  };

  const chooseAttachments = (fileList: FileList | null) => {
    setComposerError(null);
    if (!supportsAttachments) {
      setComposerError('Cursor Agent accepts prompts only in Glasstunnel.');
      return;
    }
    if (!fileList || fileList.length === 0) return;

    const remainingSlots = MAX_ATTACHMENTS - attachmentsRef.current.length;
    if (remainingSlots <= 0) {
      setComposerError(`You can attach up to ${MAX_ATTACHMENTS} files at once.`);
      return;
    }

    const selected = Array.from(fileList);
    const accepted: PendingAttachment[] = [];
    const rejected: string[] = [];
    let pendingBatchBytes = attachmentTotalBytes(attachmentsRef.current);

    for (const file of selected) {
      if (accepted.length >= remainingSlots) {
        rejected.push(`Only ${remainingSlots} more file${remainingSlots === 1 ? '' : 's'} can be added`);
        break;
      }
      if (file.size === 0) {
        rejected.push(`${file.name || 'Untitled'} is empty`);
        continue;
      }
      if (file.size > MAX_ATTACHMENT_BYTES) {
        rejected.push(`${file.name || 'Untitled'} is over ${formatBytes(MAX_ATTACHMENT_BYTES)}`);
        continue;
      }
      if (pendingBatchBytes + file.size > MAX_ATTACHMENT_BATCH_BYTES) {
        rejected.push(`Attachments can be up to ${formatBytes(MAX_ATTACHMENT_BATCH_BYTES)} total`);
        continue;
      }
      pendingBatchBytes += file.size;
      accepted.push({
        id: createClientId(),
        file,
        previewUrl: isImageFile(file) ? URL.createObjectURL(file) : null,
      });
    }

    if (accepted.length > 0) {
      setAttachments((current) => {
        const next = [...current, ...accepted];
        attachmentsRef.current = next;
        return next;
      });
    }
    if (rejected.length > 0) {
      setComposerError(rejected.slice(0, 2).join('. '));
    }
    if (fileInputRef.current) {
      fileInputRef.current.value = '';
    }
  };

  const submit = async () => {
    if (composerDisabled) return;
    const trimmed = prompt.trim();
    if (!trimmed && !hasAttachments) return;

    setComposerError(null);
    if (!hasAttachments) {
      const delivered = sendText(app.agentId, trimmed, true);
      if (delivered) {
        setPrompt('');
      }
      return;
    }

    setUploadingAttachments(true);
    try {
      const totalBytes = attachmentTotalBytes(attachments);
      if (totalBytes > MAX_ATTACHMENT_BATCH_BYTES) {
        throw new Error(`Attachments can be up to ${formatBytes(MAX_ATTACHMENT_BATCH_BYTES)} total.`);
      }
      const batchId = createClientId();
      const files = await Promise.all(attachments.map(async (attachment, fileIndex) => {
        const bytes = new Uint8Array(await attachment.file.arrayBuffer());
        if (bytes.byteLength === 0) {
          throw new Error(`${attachment.file.name || 'Selected file'} is empty.`);
        }
        if (bytes.byteLength > MAX_ATTACHMENT_BYTES) {
          throw new Error(`${attachment.file.name || 'Selected file'} is over ${formatBytes(MAX_ATTACHMENT_BYTES)}.`);
        }
        return {
          batchId,
          text: trimmed,
          filename: safeAttachmentFilename(attachment.file),
          mimeType: attachment.file.type || inferMimeType(attachment.file.name),
          fileIndex,
          fileCount: attachments.length,
          bytes,
          submitOnSend: true,
        };
      }));
      const delivered = await sendFileAttachmentBatch(app.agentId, files);
      if (!delivered) {
        throw new Error('Files were not sent. Reconnect to your Mac and try again.');
      }
      setPrompt('');
      clearAttachments();
    } catch (error) {
      setComposerError((error as Error).message || 'File upload failed.');
    } finally {
      setUploadingAttachments(false);
    }
  };

  const handleComposerPrimaryAction = () => {
    if (showStopButton) {
      sendInterrupt(app.agentId);
      return;
    }
    void submit();
  };

  return (
    <div className="gt-panel h-full w-full overflow-hidden flex flex-col">
      <header className="border-b border-[color:var(--gt-border)] px-4 py-3 flex items-start justify-between gap-3">
        <div className="min-w-0 flex flex-1 items-start gap-3">
          {onBack && (
            <button
              onClick={onBack}
              className="gt-touch-target flex h-11 w-11 shrink-0 items-center justify-center rounded-full border border-[color:var(--gt-border)] bg-surface-2 transition hover:bg-surface-3"
              aria-label="Back to projects"
              title="Back to projects"
            >
              <BackIcon />
            </button>
          )}
          <div className="min-w-0 flex-1">
          <div className="text-sm font-semibold truncate">
            {titleOverride || snapshot?.agentLabel || app.displayName}
          </div>
          <div className="gt-dim mt-1 text-xs truncate">
            {subtitleOverride || terminalSessionLabel || snapshot?.statusDetail || `Preparing ${app.displayName} context`}
          </div>
          {headerAction && <div className="mt-2">{headerAction}</div>}
          </div>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <span
            data-testid="agent-status-badge"
            className={`rounded-[4px] px-2 py-1 text-[10px] uppercase tracking-[0.18em] ${hostUnavailable ? statusColor(AgentStatus.Disconnected) : statusColor(status)}`}
          >
            {commandSurfaceMode
              ? terminalStatusLabel(status, waitingForSnapshot || targetSwitchingContext, hostUnavailable)
              : hostUnavailable
                ? 'offline'
                : genericStatusLabel(status, waitingForSnapshot)}
          </span>
        </div>
      </header>

      {showTargetSwitcher && targets.length > 1 && (
        <section className="px-4 pb-2">
          <HorizontalScrollStrip ariaLabel="Available targets">
            {targets.map((target) => {
              const targetState = commandTargetButtonState(target, readOnly, app.adapterKind);
              const display = commandTargetButtonDisplay(target, app.adapterKind);
              return (
                <button
                  key={target.targetId}
                  onClick={() => {
                    if (!targetState.canSelect) return;
                    if (onSelectTarget) {
                      onSelectTarget(target);
                      return;
                    }
                    selectTarget(app.agentId, target.targetId);
                  }}
                  disabled={readOnly}
                  aria-disabled={targetState.ariaDisabled}
                  aria-label={targetState.ariaLabel}
                  aria-pressed={targetState.ariaPressed}
                  className={`gt-touch-target min-w-[140px] max-w-[180px] shrink-0 rounded-[6px] border px-3 py-2 text-left transition ${
                    target.selected
                      ? `${targetState.canSelect ? 'cursor-pointer hover:bg-accent/18' : 'cursor-default'} border-accent/70 bg-accent/12 text-[color:var(--gt-text)]`
                      : 'border-[color:var(--gt-border)] bg-surface-2 gt-muted hover:border-white/18 hover:bg-surface-3'
                  } disabled:opacity-40`}
                >
                  <div className="text-xs font-semibold truncate">{display.label}</div>
                  <div className="gt-dim mt-0.5 text-[11px] truncate">{display.subtitle || target.subtitle}</div>
                </button>
              );
            })}
          </HorizontalScrollStrip>
        </section>
      )}

      {snapshot?.runtimeControls && (
        <RuntimeControlsBar
          controls={snapshot.runtimeControls}
          disabled={readOnly || runtimeControlsUnavailable(status, waitingForSnapshot, hostUnavailable, snapshot.statusDetail)}
          onUpdate={(update) => updateRuntimeSettings(app.agentId, update)}
        />
      )}

      {app.hasVideo && stream && (
        <button
          onClick={() => setExpanded(true)}
          className="aspect-video w-full bg-black mx-auto border-y border-[color:var(--gt-border)]"
        >
          <VideoTile stream={stream} muted autoPlay playsInline fill />
        </button>
      )}

      <section ref={transcriptScrollRef} onScroll={commandSurfaceMode ? undefined : handleTranscriptScroll} className={mainSurfaceClass}>
        {commandSurfaceMode ? (
          <div className="flex h-full min-h-0 flex-col gap-3">
            <div className="flex min-h-0 flex-1 flex-col">
              <TerminalViewport
                app={app}
                messages={messages}
                waitingForSnapshot={waitingForSnapshot || targetSwitchingContext}
                loadingContext={loadingContext || targetSwitchingContext}
                status={status}
                hostUnavailable={hostUnavailable}
                messageEndRef={messageEndRef}
                showFrameStatus={!compactChrome}
                sharesHeightWithDecision={Boolean(pendingInputRequest)}
              />
            </div>
            {pendingInputRequest && (
              // CLI dialogs (Codex's update prompt, Claude Code's workspace
              // trust check) arrive as structured requests; the viewport only
              // shows their text, so the decision needs its own controls.
              <div className="page-scroll max-h-[60%] shrink-0 overflow-y-auto">
                <PlanningRequestCard
                  appName={app.displayName}
                  request={pendingInputRequest}
                  disabled={readOnly || hostUnavailable}
                  onSubmit={(answers) => {
                    sendInputRequestResponse({
                      agentId: app.agentId,
                      requestId: pendingInputRequest.requestId,
                      answers,
                    });
                  }}
                />
              </div>
            )}
          </div>
        ) : (
          <>
            {loadingContext && (
              <AgentLoadingState
                title={`Syncing ${app.displayName}`}
                copy={
                  waitingForSnapshot
                    ? `The Mac is reading ${app.displayName} projects and message history. Large conversations can take a moment the first time.`
                    : `${app.displayName} message history is still syncing from your Mac.`
                }
              />
            )}
            {!loadingContext && !pendingInputRequest && messages.length === 0 && (
              <AgentEmptyState
                title={`No ${app.displayName} messages yet`}
                copy={`Once ${app.displayName} writes in this thread, the latest context will appear here.`}
              />
            )}
            {messages.length > 0 && <TranscriptView agentId={app.agentId} messages={messages} />}
            {pendingInputRequest && (
              <PlanningRequestCard
                appName={app.displayName}
                request={pendingInputRequest}
                disabled={readOnly || interactionUnavailable}
                onSubmit={(answers) => {
                  sendInputRequestResponse({
                    agentId: app.agentId,
                    requestId: pendingInputRequest.requestId,
                    answers,
                  });
                }}
              />
            )}
            <div ref={messageEndRef} aria-hidden="true" />
          </>
        )}
      </section>

      <footer className={footerClass}>
        {!commandSurfaceMode && unseenMessages && (
          <div className="flex justify-center">
            <button type="button" onClick={jumpToLatest} className="gt-jump" aria-label="Jump to the latest messages">
              ↓ New messages
            </button>
          </div>
        )}
        {commandSurfaceMode && (
          <div className="mb-2 rounded-[10px] border border-emerald-300/15 bg-emerald-300/[0.06] px-3 py-2 font-mono text-[11px] leading-5 text-emerald-100/80">
            {commandSurfaceNotice(app)}
          </div>
        )}
        {supportsAttachments && hasAttachments && (
          <div className="mb-2 rounded-[8px] border border-[color:var(--gt-border)] bg-surface-2 p-2">
            <div className="mb-2 flex items-center justify-between gap-2 px-1">
              <div className="text-xs font-semibold">
                {attachments.length} file{attachments.length === 1 ? '' : 's'} attached
                <span className="gt-dim font-normal"> · {formatBytes(attachmentTotalBytes(attachments))}</span>
              </div>
              <button
                onClick={clearAttachments}
                disabled={composerDisabled}
                className="gt-button gt-button-secondary shrink-0 px-2.5 py-1 text-[11px]"
              >
                Clear
              </button>
            </div>
            <HorizontalScrollStrip
              ariaLabel="Attached files"
              contentClassName="flex gap-2 overflow-x-auto pb-1 scrollbar-none"
            >
              {attachments.map((attachment) => (
                <div
                  key={attachment.id}
                  className="relative flex w-32 shrink-0 flex-col gap-1 rounded-[6px] border border-[color:var(--gt-border)] bg-surface-1 p-2"
                >
                  {attachment.previewUrl ? (
                    <img
                      src={attachment.previewUrl}
                      alt={attachment.file.name}
                      className="h-16 w-full rounded-[4px] object-cover border border-[color:var(--gt-border)]"
                    />
                  ) : (
                    <div className="flex h-16 w-full items-center justify-center rounded-[4px] border border-[color:var(--gt-border)] bg-surface-3 text-[11px] font-semibold uppercase tracking-[0.16em] gt-muted">
                      {fileExtensionLabel(attachment.file)}
                    </div>
                  )}
                  <div className="truncate text-[11px] font-semibold">{attachment.file.name || 'Untitled'}</div>
                  <div className="gt-dim text-[10px]">{formatBytes(attachment.file.size)}</div>
                  <button
                    onClick={() => removeAttachment(attachment.id)}
                    disabled={composerDisabled}
                    className="gt-touch-target absolute right-1.5 top-1.5 flex h-11 w-11 items-center justify-center rounded-full border border-[color:var(--gt-border)] bg-surface-0/90 text-xs"
                    aria-label={`Remove ${attachment.file.name || 'file'}`}
                  >
                    ×
                  </button>
                </div>
              ))}
            </HorizontalScrollStrip>
          </div>
        )}
        {composerError && <div className="mb-2 text-xs text-err">{composerError}</div>}
        {!terminalMode && actionsOpen && (
          <HorizontalScrollStrip
            ariaLabel="Prompt actions"
            className="mb-2"
            contentClassName="flex overflow-x-auto gap-2 scrollbar-none"
          >
            {quickReplies.map((q) => (
              <button
                key={q.kind}
                onClick={() => {
                  sendQuick(app.agentId, q.kind);
                  setActionsOpen(false);
                }}
                disabled={composerDisabled}
                className="gt-button gt-button-secondary shrink-0 px-3 py-1.5 text-xs"
              >
                {q.label}
              </button>
            ))}
            <button
              onClick={() => {
                sendInterrupt(app.agentId);
                setActionsOpen(false);
              }}
              disabled={composerDisabled}
              className="gt-button gt-button-danger shrink-0 px-3 py-1.5 text-xs"
            >
              Interrupt
            </button>
          </HorizontalScrollStrip>
        )}
        <div className={commandSurfaceMode ? 'flex items-end gap-2 rounded-[12px] border border-white/10 bg-black/55 p-2 shadow-inner' : 'flex items-end gap-2'}>
          {supportsAttachments && (
            <>
              <input
                ref={fileInputRef}
                type="file"
                multiple
                className="hidden"
                onChange={(e) => chooseAttachments(e.target.files)}
              />
              <button
                onClick={() => fileInputRef.current?.click()}
                disabled={composerDisabled}
                className={commandSurfaceMode ? 'gt-touch-target flex h-11 w-11 shrink-0 items-center justify-center rounded-[10px] border border-white/10 bg-white/[0.06] text-base text-white/75 transition hover:bg-white/10 disabled:opacity-40' : 'gt-button gt-button-secondary h-11 w-11 shrink-0 px-0 text-base'}
                aria-label="Attach files"
                title="Attach files"
              >
                +
              </button>
            </>
          )}
          {!commandSurfaceMode && (
            <button
              onClick={() => setActionsOpen((value) => !value)}
              disabled={composerDisabled}
              className="gt-button gt-button-secondary h-11 shrink-0 px-3 text-xs"
              aria-expanded={actionsOpen}
            >
              Actions
            </button>
          )}
          {commandSurfaceMode && (
            <span className="hidden shrink-0 pl-1 font-mono text-lg text-emerald-300 sm:inline" aria-hidden="true">
              ❯
            </span>
          )}
          <textarea
            ref={inputRef}
            value={prompt}
            onChange={(e) => setPrompt(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
                e.preventDefault();
                void submit();
              }
            }}
            placeholder={
              waitingForSnapshot
                ? commandSurfaceMode ? 'Opening session...' : `Syncing ${app.displayName}...`
                : targetSwitchingContext
                  ? 'Switching session...'
                : status === AgentStatus.Error
                  ? commandSurfaceMode ? `${app.displayName} needs attention on your Mac` : `${app.displayName} needs attention on your Mac`
                : status === AgentStatus.Disconnected || hostUnavailable
                  ? 'Mac offline'
                : readOnly
                  ? 'Read-only mode'
                  : waitingForChoice
                    ? 'Answer the choices above...'
                  : hasAttachments
                    ? 'Add a note for the attached files...'
                    : commandSurfaceMode
                      ? commandSurfacePromptPlaceholder(app)
                      : 'Send a prompt...'
            }
            disabled={composerDisabled}
            className={commandSurfaceMode ? 'gt-composer-input min-h-11 max-h-32 flex-1 resize-none border-0 bg-transparent px-1 py-2 font-mono leading-6 text-white outline-none placeholder:text-white/30 disabled:opacity-50 sm:text-[15px]' : 'gt-composer-input gt-input flex-1 min-h-11 max-h-40 resize-none px-3 py-2 disabled:opacity-50 sm:text-sm'}
            rows={1}
          />
          <button
            onClick={handleComposerPrimaryAction}
            disabled={uploadingAttachments || (!showStopButton && !canSubmit)}
            className={composerPrimaryButtonClass({
              canSubmit,
              showStopButton,
              uploadingAttachments,
            })}
            aria-label={
              showStopButton
                ? 'Stop response'
                : uploadingAttachments
                  ? 'Uploading files'
                  : terminalMode
                    ? 'Run command'
                    : commandSurfaceMode
                      ? 'Send prompt'
                    : 'Send'
            }
            title={
              showStopButton
                ? 'Stop response'
                : uploadingAttachments
                  ? 'Uploading files'
                  : terminalMode
                    ? 'Run command'
                    : commandSurfaceMode
                      ? 'Send prompt'
                    : 'Send'
            }
          >
            {uploadingAttachments ? (
              <ComposerSpinnerIcon />
            ) : showStopButton ? (
              <ComposerStopIcon />
            ) : (
              <ComposerArrowUpIcon />
            )}
          </button>
        </div>
      </footer>

      {expanded && stream && (
        <div
          className="fixed inset-0 z-50 bg-black flex items-center justify-center"
          onClick={() => setExpanded(false)}
        >
          <VideoTile stream={stream} muted autoPlay playsInline />
        </div>
      )}
    </div>
  );
}

function RuntimeControlsBar({
  controls,
  disabled,
  onUpdate,
}: {
  controls: AgentRuntimeControls;
  disabled: boolean;
  onUpdate: (update: Omit<AgentRuntimeSettingsUpdate, 'agentId'>) => boolean;
}) {
  const [customModel, setCustomModel] = useState(controls.modelId ?? '');
  const canEdit = controls.editable && !disabled;
  const showModel = controls.supportsModelSelection || Boolean(controls.modelLabel);
  const showEffort = controls.supportsReasoningEffort || Boolean(controls.reasoningEffortLabel);
  const showFast = controls.supportsFastMode || controls.fastMode !== undefined;
  const selectedCustomModel = controls.modelId && !controls.modelOptions.some((option) => option.id === controls.modelId)
    ? { id: controls.modelId, label: controls.modelLabel ?? controls.modelId }
    : undefined;
  const modelOptions = selectedCustomModel ? [selectedCustomModel, ...controls.modelOptions] : controls.modelOptions;
  const hasModelOptions = modelOptions.length > 0;
  const supportsCustomProviderModel = controls.note?.toLowerCase().includes('provider/model') ?? false;
  const showCustomModelInput = controls.supportsModelSelection && controls.editable && (!hasModelOptions || supportsCustomProviderModel);
  const readOnlyPills = [
    controls.modelLabel,
    controls.reasoningEffortLabel,
    showFast ? (controls.fastMode ? 'Fast' : 'Standard') : undefined,
  ].filter(Boolean);

  useEffect(() => {
    setCustomModel(controls.modelId ?? '');
  }, [controls.modelId]);

  if (!showModel && !showEffort && !showFast && !controls.note) return null;

  const applyCustomModel = () => {
    const modelId = customModel.trim();
    if (!canEdit || modelId === (controls.modelId ?? '')) return;
    onUpdate({ modelId });
  };

  return (
    <section className="border-b border-[color:var(--gt-border)] bg-surface-1/80 px-4 py-2">
      <div className="flex flex-wrap items-center gap-2">
        <span className="gt-label mr-1">{showModel ? 'Model' : 'Settings'}</span>

        {controls.editable ? (
          <>
            {controls.supportsModelSelection && hasModelOptions && (
              <select
                aria-label="Model"
                value={controls.modelId ?? ''}
                disabled={!canEdit}
                onChange={(event) => onUpdate({ modelId: event.target.value })}
                className="h-8 max-w-[180px] rounded-[8px] border border-[color:var(--gt-border)] bg-surface-2 px-2 text-xs font-semibold outline-none disabled:opacity-40"
              >
                {modelOptions.map((option) => (
                  <option key={option.id} value={option.id}>
                    {option.label}
                  </option>
                ))}
              </select>
            )}

            {showCustomModelInput && (
              <div className="flex min-w-[180px] flex-1 items-center gap-1 sm:flex-none">
                <input
                  value={customModel}
                  disabled={!canEdit}
                  onChange={(event) => setCustomModel(event.target.value)}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter') {
                      event.preventDefault();
                      applyCustomModel();
                    }
                  }}
                  placeholder="provider/model"
                  className="h-8 min-w-0 flex-1 rounded-[8px] border border-[color:var(--gt-border)] bg-surface-2 px-2 text-xs outline-none disabled:opacity-40"
                />
                <button
                  onClick={applyCustomModel}
                  disabled={!canEdit || customModel.trim() === (controls.modelId ?? '')}
                  className="gt-button gt-button-secondary h-8 shrink-0 px-2 text-xs"
                >
                  Apply
                </button>
              </div>
            )}

            {controls.supportsReasoningEffort && controls.reasoningEffortOptions.length > 0 && (
              <>
                <span className="gt-label ml-1">Effort</span>
                <select
                  aria-label="Effort"
                  value={controls.reasoningEffort ?? ''}
                  disabled={!canEdit}
                  onChange={(event) => onUpdate({ reasoningEffort: event.target.value })}
                  className="h-8 max-w-[132px] rounded-[8px] border border-[color:var(--gt-border)] bg-surface-2 px-2 text-xs font-semibold outline-none disabled:opacity-40"
                >
                  {controls.reasoningEffortOptions.map((option) => (
                    <option key={option.id} value={option.id}>
                      {option.label}
                    </option>
                  ))}
                </select>
              </>
            )}

            {controls.supportsFastMode && (
              <button
                onClick={() => onUpdate({ fastMode: !controls.fastMode })}
                disabled={!canEdit}
                aria-pressed={controls.fastMode === true}
                className={`gt-button h-8 px-2 text-xs ${
                  controls.fastMode
                    ? 'border-ok/35 bg-ok/18 text-ok'
                    : 'gt-button-secondary'
                }`}
              >
                Fast
              </button>
            )}
          </>
        ) : (
          <>
            {readOnlyPills.map((label) => (
              <span
                key={label}
                className="rounded-[6px] border border-[color:var(--gt-border)] bg-surface-2 px-2 py-1 text-xs font-semibold"
              >
                {label}
              </span>
            ))}
          </>
        )}

        {controls.note && (
          <span className="gt-dim min-w-0 truncate text-xs">{controls.note}</span>
        )}
      </div>
    </section>
  );
}

function PlanningRequestCard({
  appName,
  request,
  disabled,
  onSubmit,
}: {
  appName: string;
  request: AgentInputRequest;
  disabled: boolean;
  onSubmit: (answers: AgentInputRequestAnswer[]) => void;
}) {
  const initialSelection = () => defaultPlanningSelections(request);
  const [selected, setSelected] = useState<Record<string, string>>(initialSelection);

  useEffect(() => {
    setSelected(defaultPlanningSelections(request));
  }, [request]);

  const complete = request.questions.every((question) => Boolean(selected[question.questionId]));
  const submit = () => {
    if (disabled || !complete) return;
    onSubmit(
      request.questions.map((question) => ({
        questionId: question.questionId,
        choiceIds: [selected[question.questionId]],
      })),
    );
  };

  return (
    <div className="rounded-[10px] border border-warn/35 bg-warn/10 p-4 shadow-sm">
      <div className="flex items-start justify-between gap-3">
        <div>
          <div className="text-sm font-semibold">{appName} needs a decision</div>
          <div className="gt-muted mt-1 text-xs">
            Choose here and Glasstunnel will continue on your Mac.
          </div>
        </div>
        <span className="rounded-[4px] bg-warn px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-surface-0">
          waiting
        </span>
      </div>

      <div className="mt-4 space-y-4">
        {request.questions.map((question, questionIndex) => (
          <section
            key={question.questionId}
            className="rounded-[8px] border border-[color:var(--gt-border)] bg-surface-1/80 p-3"
          >
            <div className="gt-dim text-[10px] uppercase tracking-[0.18em]">
              {question.header || `Question ${questionIndex + 1}`}
            </div>
            <div className="mt-2 text-sm font-semibold leading-relaxed">{question.question}</div>
            <div className="mt-3 space-y-2">
              {question.choices.map((choice) => {
                const isSelected = selected[question.questionId] === choice.choiceId;
                return (
                  <button
                    key={choice.choiceId}
                    type="button"
                    disabled={disabled}
                    onClick={() =>
                      setSelected((current) => ({
                        ...current,
                        [question.questionId]: choice.choiceId,
                      }))
                    }
                    className={`w-full rounded-[7px] border px-3 py-2 text-left transition disabled:opacity-50 ${
                      isSelected
                        ? 'border-accent/70 bg-accent/15 text-[color:var(--gt-text)]'
                        : 'border-[color:var(--gt-border)] bg-surface-2 hover:border-white/25'
                    }`}
                  >
                    <div className="flex items-start gap-2">
                      <span className="gt-dim min-w-4 text-xs">{choice.choiceId}.</span>
                      <span className="min-w-0 flex-1">
                        <span className="block text-sm font-semibold">{choice.label}</span>
                        {choice.description && (
                          <span className="gt-muted mt-1 block text-xs leading-relaxed">
                            {choice.description}
                          </span>
                        )}
                      </span>
                      {choice.recommended && (
                        <span className="rounded-full border border-ok/35 bg-ok/10 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-[0.14em] text-ok">
                          recommended
                        </span>
                      )}
                    </div>
                  </button>
                );
              })}
            </div>
          </section>
        ))}
      </div>

      <div className="mt-4 flex justify-end">
        <button
          type="button"
          onClick={submit}
          disabled={disabled || !complete}
          className="gt-button gt-button-primary px-4 py-2 text-sm disabled:opacity-40"
        >
          Continue
        </button>
      </div>
    </div>
  );
}

function defaultPlanningSelections(request: AgentInputRequest): Record<string, string> {
  return Object.fromEntries(
    request.questions.map((question) => {
      const recommended = question.choices.find((choice) => choice.recommended);
      const fallback = question.choices[0];
      return [question.questionId, recommended?.choiceId ?? fallback?.choiceId ?? ''];
    }),
  );
}

function composerPrimaryButtonClass({
  canSubmit,
  showStopButton,
  uploadingAttachments,
}: {
  canSubmit: boolean;
  showStopButton: boolean;
  uploadingAttachments: boolean;
}): string {
  const base =
    'gt-touch-target flex h-11 w-11 shrink-0 items-center justify-center rounded-full border transition duration-150 focus:outline-none focus:ring-2 focus:ring-white/30';
  if (uploadingAttachments) {
    return `${base} cursor-wait border-white/20 bg-white/20 text-white/70`;
  }
  if (showStopButton || canSubmit) {
    return `${base} border-white bg-white text-black shadow-sm hover:bg-white/90 active:scale-95`;
  }
  return `${base} cursor-not-allowed border-transparent bg-white/20 text-white/55`;
}

function ComposerArrowUpIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      aria-hidden="true"
      className="h-5 w-5"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.4"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M12 19V5" />
      <path d="M5.5 11.5 12 5l6.5 6.5" />
    </svg>
  );
}

function ComposerStopIcon() {
  return <span aria-hidden="true" className="h-3.5 w-3.5 rounded-[3px] bg-current" />;
}

function ComposerSpinnerIcon() {
  return (
    <span
      aria-hidden="true"
      className="h-4 w-4 rounded-full border-2 border-current/25 border-t-current animate-spin"
    />
  );
}

function BackIcon() {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true" className="h-4 w-4">
      <path
        d="M12.5 4.5 7 10l5.5 5.5"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function AgentLoadingState({ title, copy }: { title: string; copy: string }) {
  return (
    <div className="flex min-h-[240px] items-center justify-center py-8">
      <div className="max-w-sm rounded-[10px] border border-[color:var(--gt-border)] bg-surface-2 px-5 py-5 text-center shadow-sm">
        <div className="mx-auto flex h-10 w-10 items-center justify-center rounded-[10px] border border-accent/30 bg-accent/10">
          <div className="h-4 w-4 rounded-full border-2 border-accent/25 border-t-accent animate-spin" />
        </div>
        <div className="mt-4 text-sm font-semibold">{title}</div>
        <div className="gt-muted mt-2 text-xs leading-relaxed">{copy}</div>
      </div>
    </div>
  );
}

function AgentEmptyState({ title, copy }: { title: string; copy: string }) {
  return (
    <div className="flex min-h-[220px] items-center justify-center py-8">
      <div className="max-w-sm text-center">
        <div className="mx-auto flex h-10 w-10 items-center justify-center rounded-[10px] border border-[color:var(--gt-border)] bg-surface-2 gt-muted">
          []
        </div>
        <div className="mt-4 text-sm font-semibold">{title}</div>
        <div className="gt-muted mt-2 text-xs leading-relaxed">{copy}</div>
      </div>
    </div>
  );
}

function TerminalViewport({
  app,
  messages,
  waitingForSnapshot,
  loadingContext,
  status,
  hostUnavailable,
  messageEndRef,
  showFrameStatus,
  sharesHeightWithDecision = false,
}: {
  app: RemoteApp;
  messages: AgentChatMessage[];
  waitingForSnapshot: boolean;
  loadingContext: boolean;
  status: AgentStatus;
  hostUnavailable: boolean;
  messageEndRef: RefObject<HTMLDivElement>;
  showFrameStatus: boolean;
  /** A pending decision sits below the viewport, so it may shrink further. */
  sharesHeightWithDecision?: boolean;
}) {
  const title = app.statusDetail || app.windowTitle || 'local shell';
  const hasMessages = messages.length > 0;
  const minHeightClass = sharesHeightWithDecision ? 'min-h-[132px]' : 'min-h-[240px]';

  return (
    <div className={`flex h-full ${minHeightClass} w-full min-w-0 max-w-full flex-1 flex-col overflow-hidden rounded-[18px] border border-white/10 bg-[#050505] shadow-[inset_0_1px_0_rgba(255,255,255,0.08)] ${sharesHeightWithDecision ? '' : 'sm:min-h-[360px]'}`}>
      <div className="flex h-11 shrink-0 items-center justify-between border-b border-white/10 bg-white/[0.035] px-3">
        <div className="flex items-center gap-1.5" aria-hidden="true">
          <span className="h-3 w-3 rounded-full bg-[#ff5f57]" />
          <span className="h-3 w-3 rounded-full bg-[#febc2e]" />
          <span className="h-3 w-3 rounded-full bg-[#28c840]" />
        </div>
        <div className="min-w-0 flex-1 px-3 text-center font-mono text-[11px] text-white/45 truncate">
          {title}
        </div>
        {showFrameStatus && (
          <span
            data-testid="terminal-frame-status"
            className={`shrink-0 rounded-full px-2 py-1 font-mono text-[10px] uppercase tracking-[0.14em] ${terminalStatusTone(status, waitingForSnapshot, hostUnavailable)}`}
          >
            {terminalStatusLabel(status, waitingForSnapshot, hostUnavailable)}
          </span>
        )}
      </div>

      <div className="page-scroll flex-1 overflow-y-auto px-3 py-4 font-mono text-[13px] leading-6 text-[#f4f4f5] sm:px-4 sm:text-sm">
        {waitingForSnapshot || loadingContext ? (
          <TerminalSystemLine text={terminalLoadingText(app.displayName)} />
        ) : null}
        {!waitingForSnapshot && !loadingContext && !hasMessages ? (
          <div className="flex items-center gap-2 text-white/45">
            <span className="text-emerald-300">❯</span>
            <span>{terminalEmptyText()}</span>
            <span className="animate-pulse text-white/70">▌</span>
          </div>
        ) : null}
        {messages.map((message) => (
          <TerminalOutputLine key={message.messageId} message={message} />
        ))}
        <div ref={messageEndRef} aria-hidden="true" />
      </div>
    </div>
  );
}

function TerminalOutputLine({ message }: { message: AgentChatMessage }) {
  const timestamp = formatMessageTimestamp(message.atUnixMs);
  const ownMessage = message.role === ChatRole.User;
  const systemMessage = message.role === ChatRole.System;
  const toolMessage = message.role === ChatRole.Tool;

  return (
    <div className={`group min-w-0 overflow-hidden border-l-2 py-2 pl-3 ${terminalLineTone(message.role)}`}>
      <div className="grid min-w-0 grid-cols-[auto_minmax(0,1fr)] items-start gap-2 sm:grid-cols-[auto_minmax(0,1fr)_auto]">
        <span className={`mt-0.5 shrink-0 ${ownMessage ? 'text-emerald-300' : systemMessage ? 'text-warn' : toolMessage ? 'text-accent' : 'text-white/30'}`}>
          {ownMessage ? '❯' : systemMessage ? '!' : toolMessage ? '↳' : ' '}
        </span>
        <pre
          className="m-0 min-w-0 max-w-full overflow-hidden whitespace-pre-wrap break-words font-mono text-[inherit] leading-[inherit]"
          style={{ overflowWrap: 'anywhere' }}
        >
          {message.text || ' '}
        </pre>
        {timestamp && (
          <time
            dateTime={timestamp.iso}
            title={timestamp.full}
            aria-label={`Created ${timestamp.full}`}
            className="ml-2 hidden shrink-0 pt-0.5 font-mono text-[10px] leading-none text-white/25 group-hover:text-white/45 sm:block"
          >
            {timestamp.label}
          </time>
        )}
      </div>
      {message.redacted && (
        <div className="mt-1 pl-6 text-[10px] uppercase tracking-[0.14em] text-warn/70">
          redacted
          {message.redactionReasons && message.redactionReasons.length > 0
            ? ` · ${message.redactionReasons.slice(0, 2).join(', ')}${message.redactionReasons.length > 2 ? '…' : ''}`
            : ''}
        </div>
      )}
    </div>
  );
}

function TerminalSystemLine({ text }: { text: string }) {
  return (
    <div className="mb-2 flex items-center gap-2 text-white/45">
      <span className="h-3 w-3 rounded-full border-2 border-white/20 border-t-white/70 animate-spin" />
      <span>{text}</span>
    </div>
  );
}

export function isTerminalApp(app: RemoteApp): boolean {
  return app.adapterKind === AdapterKind.Terminal || app.remoteAppId === 'terminal';
}

export function isCommandSurfaceApp(app: RemoteApp): boolean {
  return isTerminalApp(app) || isCliBackedApp(app);
}

function isCliBackedApp(app: RemoteApp): boolean {
  return (
    app.adapterKind === AdapterKind.CodexCli ||
    app.adapterKind === AdapterKind.CursorAgent ||
    app.adapterKind === AdapterKind.OpenCode ||
    app.adapterKind === AdapterKind.ClaudeCode ||
    app.adapterKind === AdapterKind.GeminiCli ||
    app.remoteAppId === 'codex-cli' ||
    app.remoteAppId === 'cursor-agent' ||
    app.remoteAppId === 'opencode' ||
    app.remoteAppId === 'claude-code' ||
    app.remoteAppId === 'gemini-cli'
  );
}

function terminalLineTone(role: ChatRole): string {
  switch (role) {
    case ChatRole.User:
      return 'border-emerald-400/35 text-emerald-50';
    case ChatRole.System:
      return 'border-warn/40 text-warn';
    case ChatRole.Tool:
      return 'border-accent/35 text-accent/90';
    default:
      return 'border-transparent text-white/90';
  }
}

function terminalStatusTone(status: AgentStatus, waitingForSnapshot: boolean, hostUnavailable = false): string {
  if (hostUnavailable) return 'bg-err/12 text-err';
  if (waitingForSnapshot) return 'bg-accent/12 text-accent';
  switch (status) {
    case AgentStatus.Idle:
    case AgentStatus.Done:
      return 'bg-ok/12 text-ok';
    case AgentStatus.Working:
    case AgentStatus.WaitingInput:
      return 'bg-accent/12 text-accent';
    case AgentStatus.Error:
    case AgentStatus.Disconnected:
      return 'bg-err/12 text-err';
    default:
      return 'bg-white/10 text-white/50';
  }
}

function genericStatusLabel(status: AgentStatus, waitingForSnapshot: boolean): string {
  if (waitingForSnapshot) return 'loading';
  switch (status) {
    case AgentStatus.Idle:
      return 'idle';
    case AgentStatus.Working:
      return 'working';
    case AgentStatus.WaitingInput:
      return 'waiting';
    case AgentStatus.AwaitingApproval:
      return 'approve?';
    case AgentStatus.Done:
      return 'done';
    case AgentStatus.Error:
      return 'error';
    case AgentStatus.Disconnected:
      return 'offline';
    default:
      return '?';
  }
}

function revokeAttachmentPreviews(items: PendingAttachment[]) {
  for (const attachment of items) {
    if (attachment.previewUrl) {
      URL.revokeObjectURL(attachment.previewUrl);
    }
  }
}

function isImageFile(file: File): boolean {
  return (file.type || inferMimeType(file.name)).startsWith('image/');
}

function attachmentTotalBytes(items: PendingAttachment[]): number {
  return items.reduce((total, attachment) => total + attachment.file.size, 0);
}

function safeAttachmentFilename(file: File): string {
  const original = file.name.trim() || 'upload';
  const dot = original.lastIndexOf('.');
  const stem = (dot > 0 ? original.slice(0, dot) : original)
    .replace(/[^a-zA-Z0-9-_]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 48) || 'upload';
  const ext = extensionFor(file.type || inferMimeType(original), original);
  return `${stem}.${ext}`;
}

function extensionFor(mimeType: string, fallbackName: string): string {
  const ext = fallbackName.split('.').pop()?.toLowerCase();
  if (ext && ext.length <= 12) {
    const sanitized = ext.replace(/[^a-z0-9]+/g, '');
    if (sanitized) return sanitized;
  }
  return mimeExtension(mimeType) ?? 'bin';
}

function inferMimeType(filename: string): string {
  const ext = filename.split('.').pop()?.toLowerCase();
  return ext ? (mimeByExtension[ext] ?? 'application/octet-stream') : 'application/octet-stream';
}

function mimeExtension(mimeType: string): string | null {
  return extensionByMime[mimeType.toLowerCase()] ?? null;
}

function fileExtensionLabel(file: File): string {
  const ext = extensionFor(file.type || inferMimeType(file.name), file.name);
  return ext.slice(0, 5) || 'file';
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

const mimeByExtension: Record<string, string> = {
  ai: 'application/postscript',
  aif: 'audio/aiff',
  aiff: 'audio/aiff',
  avi: 'video/x-msvideo',
  bmp: 'image/bmp',
  c: 'text/x-c',
  cpp: 'text/x-c++',
  cs: 'text/x-csharp',
  css: 'text/css',
  csv: 'text/csv',
  diff: 'text/x-diff',
  doc: 'application/msword',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  gif: 'image/gif',
  go: 'text/x-go',
  gz: 'application/gzip',
  heic: 'image/heic',
  heif: 'image/heif',
  html: 'text/html',
  jpeg: 'image/jpeg',
  jpg: 'image/jpeg',
  js: 'text/javascript',
  json: 'application/json',
  jsonl: 'application/jsonl',
  jsx: 'text/jsx',
  key: 'application/vnd.apple.keynote',
  log: 'text/plain',
  m4a: 'audio/mp4',
  md: 'text/markdown',
  mov: 'video/quicktime',
  mp3: 'audio/mpeg',
  mp4: 'video/mp4',
  numbers: 'application/vnd.apple.numbers',
  pages: 'application/vnd.apple.pages',
  pdf: 'application/pdf',
  php: 'text/x-php',
  png: 'image/png',
  ppt: 'application/vnd.ms-powerpoint',
  pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  py: 'text/x-python',
  rb: 'text/x-ruby',
  rs: 'text/x-rust',
  rtf: 'application/rtf',
  sh: 'text/x-shellscript',
  svg: 'image/svg+xml',
  swift: 'text/x-swift',
  tar: 'application/x-tar',
  ts: 'text/typescript',
  tsx: 'text/tsx',
  txt: 'text/plain',
  wav: 'audio/wav',
  webm: 'video/webm',
  webp: 'image/webp',
  xls: 'application/vnd.ms-excel',
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  xml: 'application/xml',
  yaml: 'application/yaml',
  yml: 'application/yaml',
  zip: 'application/zip',
};

const extensionByMime: Record<string, string> = {
  'application/gzip': 'gz',
  'application/json': 'json',
  'application/jsonl': 'jsonl',
  'application/msword': 'doc',
  'application/pdf': 'pdf',
  'application/postscript': 'ai',
  'application/rtf': 'rtf',
  'application/vnd.apple.keynote': 'key',
  'application/vnd.apple.numbers': 'numbers',
  'application/vnd.apple.pages': 'pages',
  'application/vnd.ms-excel': 'xls',
  'application/vnd.ms-powerpoint': 'ppt',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': 'pptx',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
  'application/x-tar': 'tar',
  'application/xml': 'xml',
  'application/yaml': 'yaml',
  'application/zip': 'zip',
  'audio/aiff': 'aiff',
  'audio/mpeg': 'mp3',
  'audio/mp4': 'm4a',
  'audio/wav': 'wav',
  'image/bmp': 'bmp',
  'image/gif': 'gif',
  'image/heic': 'heic',
  'image/heif': 'heif',
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/png': 'png',
  'image/svg+xml': 'svg',
  'image/webp': 'webp',
  'text/css': 'css',
  'text/csv': 'csv',
  'text/html': 'html',
  'text/javascript': 'js',
  'text/markdown': 'md',
  'text/plain': 'txt',
  'text/typescript': 'ts',
  'video/mp4': 'mp4',
  'video/quicktime': 'mov',
  'video/webm': 'webm',
  'video/x-msvideo': 'avi',
};
