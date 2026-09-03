import { useCallback, useEffect, useMemo, useRef, useState, type PointerEvent } from 'react';
import type {
  AgentStateSnapshot,
  RemoteApp,
  ScreenPointerAction,
  ScreenShareQuality,
} from '@glasstunnel/protocol';
import { AgentStatus } from '@glasstunnel/protocol';
import { useAppStore } from '../lib/store';
import {
  describeScreenVideoStatus,
  hasFreshRelayScreenFrame,
  hasRenderableVideoFrame,
  SCREEN_VIDEO_ELEMENT_EVENTS,
  type ScreenVideoElementEvent,
  type ScreenVideoRenderPhase,
  type ScreenVideoStatus,
} from './screenVideoStatus';
import { collectScreenVideoDiagnostics } from './screenVideoDiagnostics';

interface ScreenRemotePanelProps {
  app: RemoteApp;
  snapshot?: AgentStateSnapshot;
  onBack?: () => void;
  hostOnline: boolean | null;
  connectionError: string | null;
  onRetryConnection: () => void;
}

const VIDEO_FRAME_TIMEOUT_MS = 7_000;
const VIDEO_RESUME_RESTART_MS = 6_000;
const VIDEO_ATTACH_RETRY_MS = 1_200;
const VIDEO_FRAME_PROBE_MS = 250;
const VIDEO_DIAGNOSTICS_MS = 1_500;

export function ScreenRemotePanel({
  app,
  snapshot,
  onBack,
  hostOnline,
  connectionError,
  onRetryConnection,
}: ScreenRemotePanelProps) {
  const stream = useAppStore((s) => s.videoStreams[app.agentId]);
  const relayFrame = useAppStore((s) => s.relayScreenFrames[app.agentId]);
  const readOnlyMode = useAppStore((s) => s.readOnlyMode);
  const requestRemoteAppAction = useAppStore((s) => s.requestRemoteAppAction);
  const startVideoPeer = useAppStore((s) => s.startVideoPeer);
  const stopVideoPeer = useAppStore((s) => s.stopVideoPeer);
  const clearVideoStream = useAppStore((s) => s.clearVideoStream);
  const clearRelayScreenFrame = useAppStore((s) => s.clearRelayScreenFrame);
  const screenShareQuality = useAppStore((s) => s.screenShareQuality);
  const setScreenShareQuality = useAppStore((s) => s.setScreenShareQuality);
  const sendScreenPointer = useAppStore((s) => s.sendScreenPointer);
  const sendText = useAppStore((s) => s.sendText);
  const peer = useAppStore((s) => s.peer);
  const pairedHostDeviceId = useAppStore((s) => s.pairedHost?.deviceId ?? null);
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const startRequestedRef = useRef(false);
  const streamAttachedAtRef = useRef(0);
  const lastResumeRestartAtRef = useRef(0);
  const qualityNoticeTimerRef = useRef<number | null>(null);
  const [zoom, setZoom] = useState(1);
  const [text, setText] = useState('');
  const [now, setNow] = useState(() => Date.now());
  const [videoRenderPhase, setVideoRenderPhase] = useState<ScreenVideoRenderPhase>('idle');
  const [videoRenderDetail, setVideoRenderDetail] = useState<string | null>(null);
  const [qualityNotice, setQualityNotice] = useState<string | null>(null);
  const captureError =
    snapshot?.status === AgentStatus.Error && snapshot.statusDetail ? snapshot.statusDetail : null;
  const screenSharingEnabled = app.enabled;
  const screenStopping = isScreenStoppingDetail(snapshot?.statusDetail ?? app.statusDetail);
  const relayFrameIsFresh = hasFreshRelayScreenFrame(relayFrame, now);
  const videoIsReady = Boolean(stream) && videoRenderPhase === 'ready';
  const showRelayFrame = screenSharingEnabled && relayFrameIsFresh && !videoIsReady;
  const showVideo = screenSharingEnabled && Boolean(stream) && !showRelayFrame;

  const requestScreenStart = useCallback(
    (quality: ScreenShareQuality = screenShareQuality) =>
      requestRemoteAppAction(app.remoteAppId, 'start', { screenQuality: quality }),
    [app.remoteAppId, requestRemoteAppAction, screenShareQuality],
  );

  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 2_000);
    return () => window.clearInterval(timer);
  }, []);

  useEffect(() => {
    setText('');
  }, [pairedHostDeviceId, app.agentId]);

  const showQualityNotice = useCallback((notice: string) => {
    setQualityNotice(notice);
    if (qualityNoticeTimerRef.current !== null) {
      window.clearTimeout(qualityNoticeTimerRef.current);
    }
    qualityNoticeTimerRef.current = window.setTimeout(() => {
      setQualityNotice(null);
      qualityNoticeTimerRef.current = null;
    }, 2_600);
  }, []);

  useEffect(() => {
    return () => {
      if (qualityNoticeTimerRef.current !== null) {
        window.clearTimeout(qualityNoticeTimerRef.current);
      }
    };
  }, []);

  useEffect(() => {
    if (!screenSharingEnabled) {
      startRequestedRef.current = false;
      stopVideoPeer(app.agentId);
      setVideoRenderPhase('idle');
      setVideoRenderDetail(null);
      return;
    }
    if (hostOnline !== true) {
      startRequestedRef.current = false;
      return;
    }
    if (stream) return;

    if (!startRequestedRef.current) {
      startRequestedRef.current = true;
      requestScreenStart();
    }
    void startVideoPeer();
  }, [
    app.agentId,
    hostOnline,
    requestScreenStart,
    screenSharingEnabled,
    startVideoPeer,
    stopVideoPeer,
    stream,
  ]);

  useEffect(() => {
    const video = videoRef.current;
    if (!stream) {
      setVideoRenderPhase('idle');
      setVideoRenderDetail(null);
      if (video) video.srcObject = null;
      return;
    }
    if (!video) return;

    let closed = false;
    let attachRetryCount = 0;
    let attachRetryTimer: number | null = null;
    let frameProbeTimer: number | null = null;
    streamAttachedAtRef.current = Date.now();
    setVideoRenderPhase('syncing');
    setVideoRenderDetail(null);

    const stopFrameProbe = () => {
      if (frameProbeTimer !== null) {
        window.clearInterval(frameProbeTimer);
        frameProbeTimer = null;
      }
    };

    const updateRenderableState = (
      fallback: ScreenVideoRenderPhase = 'syncing',
      detail?: string | null,
    ) => {
      if (closed) return;
      if (hasRenderableVideoFrame(video)) {
        stopFrameProbe();
        setVideoRenderPhase('ready');
        setVideoRenderDetail(null);
        return;
      }
      setVideoRenderPhase(fallback);
      if (detail !== undefined) {
        setVideoRenderDetail(detail);
      }
    };

    const playStream = () => {
      if (closed) return;
      const play = video.play();
      if (play) {
        void play.catch(() => {
          updateRenderableState(
            'error',
            'This browser blocked video playback. Retry screen to start again.',
          );
        });
      }
    };
    const reattachStream = () => {
      if (closed || hasRenderableVideoFrame(video) || attachRetryCount >= 3) return;
      attachRetryCount += 1;
      video.srcObject = null;
      window.setTimeout(() => {
        if (closed) return;
        video.srcObject = stream;
        playStream();
      }, 0);
      attachRetryTimer = window.setTimeout(reattachStream, VIDEO_ATTACH_RETRY_MS);
    };
    const markSyncing = () => {
      playStream();
      updateRenderableState('syncing');
    };
    const markStalled = () =>
      updateRenderableState(
        'stalled',
        'A screen track connected, but this browser has not rendered a frame yet.',
      );
    const markVideoError = () =>
      updateRenderableState('error', 'This browser could not play the screen stream.');
    const markTrackEnded = () => {
      clearVideoStream(app.agentId);
      setVideoRenderPhase('idle');
      setVideoRenderDetail(null);
    };

    video.srcObject = stream;
    video.defaultMuted = true;
    video.muted = true;
    video.autoplay = true;
    video.playsInline = true;
    video.setAttribute('playsinline', '');
    video.setAttribute('webkit-playsinline', '');

    const listenerForVideoEvent = (eventName: ScreenVideoElementEvent) => {
      if (eventName === 'stalled') return markStalled;
      if (eventName === 'error') return markVideoError;
      return markSyncing;
    };
    const listeners = SCREEN_VIDEO_ELEMENT_EVENTS.map(
      (eventName) => [eventName, listenerForVideoEvent(eventName)] as const,
    );
    for (const [eventName, listener] of listeners) {
      video.addEventListener(eventName, listener);
    }

    for (const track of stream.getVideoTracks()) {
      track.addEventListener('ended', markTrackEnded);
      track.addEventListener('mute', markSyncing);
      track.addEventListener('unmute', markSyncing);
    }

    playStream();

    const frame = window.requestAnimationFrame(markSyncing);
    frameProbeTimer = window.setInterval(
      () => updateRenderableState('syncing'),
      VIDEO_FRAME_PROBE_MS,
    );
    attachRetryTimer = window.setTimeout(reattachStream, VIDEO_ATTACH_RETRY_MS);
    const timeout = window.setTimeout(markStalled, VIDEO_FRAME_TIMEOUT_MS);

    return () => {
      closed = true;
      window.cancelAnimationFrame(frame);
      if (attachRetryTimer !== null) window.clearTimeout(attachRetryTimer);
      stopFrameProbe();
      window.clearTimeout(timeout);
      for (const [eventName, listener] of listeners) {
        video.removeEventListener(eventName, listener);
      }
      for (const track of stream.getVideoTracks()) {
        track.removeEventListener('ended', markTrackEnded);
        track.removeEventListener('mute', markSyncing);
        track.removeEventListener('unmute', markSyncing);
      }
      if (video.srcObject === stream) {
        video.srcObject = null;
      }
    };
  }, [app.agentId, clearVideoStream, stream]);

  useEffect(() => {
    const video = videoRef.current;
    const pc = peer?.pc ?? null;
    if (!stream || !video || !pc || videoRenderPhase === 'ready') return;

    let closed = false;
    const updateDiagnostics = async () => {
      try {
        const diagnostics = await collectScreenVideoDiagnostics(pc, stream, video);
        if (!closed && !hasRenderableVideoFrame(video)) {
          setVideoRenderDetail(diagnostics.detail);
        }
      } catch {
        if (!closed && !hasRenderableVideoFrame(video)) {
          setVideoRenderDetail('This browser could not read screen-video diagnostics yet.');
        }
      }
    };

    void updateDiagnostics();
    const timer = window.setInterval(() => {
      void updateDiagnostics();
    }, VIDEO_DIAGNOSTICS_MS);

    return () => {
      closed = true;
      window.clearInterval(timer);
    };
  }, [peer, stream, videoRenderPhase]);

  const status = useMemo(() => {
    return describeScreenVideoStatus({
      screenEnabled: screenSharingEnabled,
      hostOnline,
      captureError,
      connectionError,
      hasStream: Boolean(stream) || showRelayFrame,
      renderPhase: videoIsReady || showRelayFrame ? 'ready' : videoRenderPhase,
    });
  }, [
    captureError,
    connectionError,
    hostOnline,
    screenSharingEnabled,
    showRelayFrame,
    stream,
    videoIsReady,
    videoRenderPhase,
  ]);

  useEffect(() => {
    const restartIfNeeded = () => {
      if (document.visibilityState === 'hidden') return;
      if (hostOnline !== true || !stream || status.canControl) return;
      if (Date.now() - streamAttachedAtRef.current < VIDEO_RESUME_RESTART_MS) return;
      if (Date.now() - lastResumeRestartAtRef.current < VIDEO_RESUME_RESTART_MS) return;
      lastResumeRestartAtRef.current = Date.now();
      requestScreenStart();
      void startVideoPeer();
    };
    const onVisibilityChange = () => {
      if (document.visibilityState === 'visible') restartIfNeeded();
    };
    window.addEventListener('focus', restartIfNeeded);
    window.addEventListener('online', restartIfNeeded);
    window.addEventListener('pageshow', restartIfNeeded);
    document.addEventListener('visibilitychange', onVisibilityChange);
    return () => {
      window.removeEventListener('focus', restartIfNeeded);
      window.removeEventListener('online', restartIfNeeded);
      window.removeEventListener('pageshow', restartIfNeeded);
      document.removeEventListener('visibilitychange', onVisibilityChange);
    };
  }, [
    hostOnline,
    requestScreenStart,
    startVideoPeer,
    status.canControl,
    stream,
  ]);

  const sendTap = (
    element: HTMLElement,
    clientX: number,
    clientY: number,
    intrinsicWidth: number,
    intrinsicHeight: number,
    detail: number,
  ) => {
    if (readOnlyMode || !status.canControl) return;
    const point = normalizedScreenPoint(element, clientX, clientY, intrinsicWidth, intrinsicHeight);
    if (!point) return;
    const action: ScreenPointerAction = detail >= 2 ? 'doubleClick' : 'click';
    sendScreenPointer(app.agentId, point.x, point.y, action);
  };

  const onVideoTap = (event: PointerEvent<HTMLVideoElement>) => {
    const video = event.currentTarget;
    sendTap(video, event.clientX, event.clientY, video.videoWidth, video.videoHeight, event.detail);
  };

  const onRelayFrameTap = (event: PointerEvent<HTMLImageElement>) => {
    if (!relayFrame) return;
    sendTap(
      event.currentTarget,
      event.clientX,
      event.clientY,
      relayFrame.width,
      relayFrame.height,
      event.detail,
    );
  };

  const typeOnMac = (submit: boolean) => {
    const trimmed = text.trim();
    if (!trimmed) return;
    const delivered = sendText(app.agentId, trimmed, submit);
    if (delivered) {
      setText('');
    }
  };

  const retryScreen = () => {
    startRequestedRef.current = false;
    clearVideoStream(app.agentId);
    clearRelayScreenFrame(app.agentId);
    setVideoRenderPhase('idle');
    setVideoRenderDetail(null);
    if (hostOnline === true) {
      // The relay is fine; only the screen stream needs a fresh start. A full
      // connection restart here would tear down the peer just started.
      requestScreenStart();
      void startVideoPeer();
      return;
    }
    onRetryConnection();
  };

  const setScreenSharing = (enabled: boolean) => {
    startRequestedRef.current = false;
    setVideoRenderPhase('idle');
    setVideoRenderDetail(null);
    if (enabled) {
      clearRelayScreenFrame(app.agentId);
      const delivered = requestScreenStart();
      if (delivered) {
        void startVideoPeer();
      } else {
        void onRetryConnection();
      }
      return;
    }

    stopVideoPeer(app.agentId);
    requestRemoteAppAction(app.remoteAppId, 'stop');
  };

  const chooseQuality = (quality: ScreenShareQuality) => {
    if (screenShareQuality === quality) return;
    setScreenShareQuality(quality);
    if (!screenSharingEnabled) {
      showQualityNotice(screenQualityNotice({ quality, state: 'saved' }));
      return;
    }
    if (hostOnline !== true) {
      showQualityNotice(screenQualityNotice({ quality, state: 'offline' }));
      return;
    }
    const delivered = requestRemoteAppAction(app.remoteAppId, 'start', { screenQuality: quality });
    showQualityNotice(
      screenQualityNotice({ quality, state: delivered ? 'switching' : 'failed' }),
    );
    if (!delivered) {
      onRetryConnection();
    }
  };

  return (
    <section className="flex h-full min-h-0 w-full max-w-[390px] flex-col bg-surface-0 sm:max-w-none">
      <div className="flex shrink-0 items-center gap-3 border-b border-[color:var(--gt-border)] px-4 py-3">
        {onBack && (
          <button
            type="button"
            onClick={onBack}
            className="flex h-10 w-10 items-center justify-center rounded-full bg-white/[0.06] text-white transition hover:bg-white/12"
            aria-label="Back"
          >
            <BackIcon />
          </button>
        )}
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <h2 className="truncate text-lg font-semibold">Mac Screen</h2>
            <span className={`h-2 w-2 rounded-full ${statusDotClass(status.tone)}`} />
          </div>
          <p className="gt-muted truncate text-sm">{status.label}</p>
        </div>
        <ScreenSharingSwitch
          enabled={screenSharingEnabled}
          disabled={hostOnline === false}
          onToggle={setScreenSharing}
        />
      </div>

      <div className="flex shrink-0 flex-wrap items-center gap-2 border-b border-[color:var(--gt-border)] px-4 py-2">
        <SegmentedControl
          label="Screen quality"
          className="min-w-[11rem] flex-1"
          options={[
            { value: 'fast', label: 'Fast' },
            { value: 'readable', label: 'Readable' },
          ]}
          value={screenShareQuality}
          onChange={(value) => chooseQuality(value as ScreenShareQuality)}
        />
        {qualityNotice && (
          <div className="min-w-full text-xs font-medium text-white/55 md:min-w-0">
            {qualityNotice}
          </div>
        )}
        <div
          className="flex shrink-0 items-center gap-2 rounded-full bg-white/[0.06] p-1"
          aria-label="Screen zoom"
        >
          {[1, 2, 4].map((value) => (
            <button
              key={value}
              type="button"
              onClick={() => setZoom(value)}
              aria-label={`Zoom ${value}x`}
              className={`inline-flex min-w-12 items-center justify-center gap-1.5 rounded-full px-3 py-1.5 text-xs font-semibold transition ${
                zoom === value
                  ? 'bg-white text-black'
                  : 'text-white/70 hover:bg-white/10 hover:text-white'
              }`}
            >
              <MagnifierIcon />
              <span>{value}x</span>
            </button>
          ))}
        </div>
      </div>

      <div className="min-h-0 flex-1 overflow-auto bg-black/50 p-3">
        <div className="mx-auto flex min-h-full max-w-6xl items-center justify-center">
          <div className="relative overflow-auto rounded-[24px] border border-white/12 bg-black shadow-2xl">
            {showVideo ? (
              <>
                <video
                  ref={videoRef}
                  autoPlay
                  muted
                  playsInline
                  onPointerUp={onVideoTap}
                  className={`block max-h-none min-h-[260px] object-contain ${
                    readOnlyMode || !status.canControl ? 'cursor-not-allowed' : 'cursor-crosshair'
                  }`}
                  style={{ width: `${zoom * 100}%`, maxWidth: 'none' }}
                />
                {!status.canControl && (
                  <VideoOverlay
                    status={status}
                    detail={videoRenderDetail ?? captureError ?? connectionError}
                    onRetry={retryScreen}
                  />
                )}
              </>
            ) : showRelayFrame && relayFrame ? (
              <img
                src={`data:${relayFrame.mimeType};base64,${relayFrame.bytes}`}
                width={relayFrame.width}
                height={relayFrame.height}
                alt="Mac screen"
                draggable={false}
                onPointerUp={onRelayFrameTap}
                className={`block max-h-none min-h-[260px] select-none object-contain ${
                  readOnlyMode || !status.canControl ? 'cursor-not-allowed' : 'cursor-crosshair'
                }`}
                style={{ width: `${zoom * 100}%`, maxWidth: 'none' }}
              />
            ) : (
              <div className="flex min-h-[360px] w-full max-w-[22rem] items-center justify-center p-6 text-center sm:max-w-[880px] sm:p-8">
                <div className="max-w-[18rem] sm:max-w-sm">
                  <div
                    className={`mx-auto flex h-14 w-14 items-center justify-center rounded-[18px] border ${statusPanelClass(status.tone)}`}
                  >
                    <ScreenIcon />
                  </div>
                  <h3 className="mt-5 text-2xl font-semibold">
                    {!screenSharingEnabled
                      ? 'Screen sharing off'
                      : hostOnline === false
                        ? 'Mac offline'
                        : screenStopping
                          ? screenStoppingTitle()
                          : 'Waiting for screen'}
                  </h3>
                  <p className="gt-muted mt-3 text-sm leading-relaxed">
                    {!screenSharingEnabled
                      ? 'Turn on screen sharing to view and control this Mac from your browser.'
                      : hostOnline === false
                        ? screenOfflineCopy()
                        : screenStopping
                          ? screenStoppingCopy()
                          : 'Glasstunnel is opening a secure screen stream. macOS may ask for Screen Recording or Accessibility permission.'}
                  </p>
                  {!screenStopping && (captureError || connectionError) && (
                    <p className="mt-4 break-words text-sm leading-relaxed text-err">
                      {captureError ?? connectionError}
                    </p>
                  )}
                  <button
                    type="button"
                    onClick={
                      screenStopping
                        ? () => setScreenSharing(false)
                        : screenSharingEnabled
                          ? retryScreen
                          : () => setScreenSharing(true)
                    }
                    className="gt-button gt-button-primary mt-5 px-5 py-2.5"
                  >
                    {screenStopping
                      ? 'Retry stop'
                      : screenSharingEnabled
                        ? 'Retry screen'
                        : 'Turn on screen sharing'}
                  </button>
                </div>
              </div>
            )}
          </div>
        </div>
      </div>

      <form
        className="flex shrink-0 items-center gap-2 border-t border-[color:var(--gt-border)] bg-surface-1 px-3 py-3 safe-pad-bottom"
        onSubmit={(event) => {
          event.preventDefault();
          typeOnMac(false);
        }}
      >
        <input
          value={text}
          onChange={(event) => setText(event.target.value)}
          placeholder={
            readOnlyMode
              ? 'Input is off'
              : status.canControl
                ? 'Type on your Mac screen...'
                : screenSharingEnabled
                  ? 'Waiting...'
                  : 'Screen off'
          }
          disabled={readOnlyMode || !status.canControl}
          className="min-w-0 flex-1 rounded-2xl border border-white/10 bg-black/35 px-4 py-3 text-base outline-none transition placeholder:text-white/35 focus:border-accent/70 disabled:cursor-not-allowed disabled:opacity-55"
        />
        <button
          type="submit"
          disabled={readOnlyMode || !status.canControl || !text.trim()}
          className="gt-button px-4 py-3 disabled:cursor-not-allowed disabled:opacity-45"
        >
          Type
        </button>
        <button
          type="button"
          onClick={() => typeOnMac(true)}
          disabled={readOnlyMode || !status.canControl || !text.trim()}
          className="gt-button gt-button-primary px-4 py-3 disabled:cursor-not-allowed disabled:opacity-45"
        >
          Type + Return
        </button>
      </form>
    </section>
  );
}

function VideoOverlay({
  status,
  detail,
  onRetry,
}: {
  status: ScreenVideoStatus;
  detail: string | null | undefined;
  onRetry: () => void;
}) {
  return (
    <div className="absolute inset-0 flex items-center justify-center bg-black/72 p-6 text-center">
      <div className="max-w-sm">
        <div
          className={`mx-auto flex h-12 w-12 items-center justify-center rounded-[16px] border ${statusPanelClass(status.tone)}`}
        >
          <ScreenIcon />
        </div>
        <h3 className="mt-4 text-xl font-semibold">{status.label}</h3>
        <p className="gt-muted mt-2 text-sm leading-relaxed">{screenOverlayCopy(status.issue)}</p>
        {detail && status.issue !== 'syncing' && (
          <p className="mt-3 text-sm leading-relaxed text-err">{detail}</p>
        )}
        {status.issue !== 'syncing' && status.issue !== 'ready' && (
          <button
            type="button"
            onClick={onRetry}
            className="gt-button gt-button-primary mt-4 px-5 py-2.5"
          >
            Retry screen
          </button>
        )}
      </div>
    </div>
  );
}

export function screenOverlayCopy(issue: ScreenVideoStatus['issue']): string {
  switch (issue) {
    case 'off':
      return 'Turn on screen sharing to view and control this Mac from your browser.';
    case 'disconnected':
      return 'The screen connection dropped. Retry to start a fresh stream.';
    case 'stalled':
      return 'A screen track connected, but this browser has not rendered a frame yet.';
    case 'video-error':
      return 'This browser could not play the screen stream. Retry starts a fresh stream.';
    case 'capture':
      return 'The Mac could not start screen capture. Check Screen Recording permission, then retry.';
    case 'offline':
      return screenOfflineCopy();
    case 'waiting':
      return 'Glasstunnel is opening a secure screen stream.';
    case 'syncing':
      return 'Waiting for this browser to render the first screen frame.';
    case 'ready':
      return 'Screen control is ready.';
  }
}

export function screenOfflineCopy(): string {
  return 'Reconnect your Mac to use screen control.';
}

export function isScreenStoppingDetail(detail: string | null | undefined): boolean {
  return detail?.trim().toLowerCase() === 'stopping stream';
}

export function screenStoppingTitle(): string {
  return 'Stopping screen sharing';
}

export function screenStoppingCopy(): string {
  return 'Waiting for the Mac to finish.';
}

export function screenQualityNotice({
  quality,
  state,
}: {
  quality: ScreenShareQuality;
  state: 'saved' | 'offline' | 'switching' | 'failed';
}): string {
  const label = quality === 'readable' ? 'Readable' : 'Fast';
  switch (state) {
    case 'saved':
      return `${label} will apply when screen sharing starts.`;
    case 'offline':
      return `${label} will apply after your Mac reconnects.`;
    case 'switching':
      return `Switching to ${label}.`;
    case 'failed':
      return `Could not switch to ${label}. Retrying connection.`;
  }
}

function ScreenSharingSwitch({
  enabled,
  disabled,
  onToggle,
}: {
  enabled: boolean;
  disabled: boolean;
  onToggle: (enabled: boolean) => void;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={enabled}
      disabled={disabled}
      onClick={() => onToggle(!enabled)}
      className={`flex shrink-0 items-center gap-2 rounded-full border px-2 py-1.5 text-xs font-semibold transition disabled:cursor-not-allowed disabled:opacity-50 ${
        enabled
          ? 'border-ok/35 bg-ok/12 text-ok'
          : 'border-white/12 bg-white/[0.05] text-white/65'
      }`}
    >
      <span className="relative h-5 w-9 rounded-full bg-black/35">
        <span
          className={`absolute top-0.5 h-4 w-4 rounded-full transition ${
            enabled ? 'left-[18px] bg-ok' : 'left-0.5 bg-white/55'
          }`}
        />
      </span>
      <span>{enabled ? 'On' : 'Off'}</span>
    </button>
  );
}

function SegmentedControl({
  label,
  className = '',
  options,
  value,
  onChange,
}: {
  label: string;
  className?: string;
  options: { value: string; label: string }[];
  value: string;
  onChange: (value: string) => void;
}) {
  return (
    <div
      className={`flex items-center gap-1 rounded-full bg-white/[0.06] p-1 ${className}`}
      aria-label={label}
    >
      {options.map((option) => (
        <button
          key={option.value}
          type="button"
          onClick={() => onChange(option.value)}
          className={`min-w-0 flex-1 rounded-full px-3 py-1.5 text-xs font-semibold transition ${
            value === option.value
              ? 'bg-white text-black'
              : 'text-white/70 hover:bg-white/10 hover:text-white'
          }`}
        >
          {option.label}
        </button>
      ))}
    </div>
  );
}

export function normalizedScreenPoint(
  element: HTMLElement,
  clientX: number,
  clientY: number,
  intrinsicWidth: number,
  intrinsicHeight: number,
) {
  const rect = element.getBoundingClientRect();
  const sourceWidth = intrinsicWidth || rect.width;
  const sourceHeight = intrinsicHeight || rect.height;
  if (rect.width <= 0 || rect.height <= 0 || sourceWidth <= 0 || sourceHeight <= 0) return null;

  const elementRatio = rect.width / rect.height;
  const videoRatio = sourceWidth / sourceHeight;
  let contentWidth = rect.width;
  let contentHeight = rect.height;
  let offsetX = 0;
  let offsetY = 0;

  if (elementRatio > videoRatio) {
    contentWidth = rect.height * videoRatio;
    offsetX = (rect.width - contentWidth) / 2;
  } else {
    contentHeight = rect.width / videoRatio;
    offsetY = (rect.height - contentHeight) / 2;
  }

  const x = (clientX - rect.left - offsetX) / contentWidth;
  const y = (clientY - rect.top - offsetY) / contentHeight;
  if (x < 0 || x > 1 || y < 0 || y > 1) return null;
  return { x, y };
}

function statusDotClass(tone: 'ok' | 'warning' | 'error') {
  if (tone === 'ok') return 'bg-ok';
  if (tone === 'warning') return 'bg-warn';
  return 'bg-err';
}

function statusPanelClass(tone: 'ok' | 'warning' | 'error') {
  if (tone === 'ok') return 'border-ok/35 bg-ok/10 text-ok';
  if (tone === 'warning') return 'border-warn/35 bg-warn/10 text-warn';
  return 'border-err/35 bg-err/10 text-err';
}

function BackIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" className="h-5 w-5" fill="none">
      <path
        d="M15 18l-6-6 6-6"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function MagnifierIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" className="h-3.5 w-3.5" fill="none">
      <circle cx="10.5" cy="10.5" r="5.5" stroke="currentColor" strokeWidth="2" />
      <path d="M15 15l4 4" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
    </svg>
  );
}

function ScreenIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" className="h-6 w-6" fill="none">
      <rect x="4" y="5" width="16" height="11" rx="2" stroke="currentColor" strokeWidth="1.8" />
      <path d="M9 20h6M12 16v4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
    </svg>
  );
}
