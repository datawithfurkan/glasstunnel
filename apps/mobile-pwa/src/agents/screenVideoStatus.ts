import {
  hasFreshRelayScreenFrameTimestamp,
  RELAY_SCREEN_FRAME_FRESH_MS,
} from '../lib/remoteApps';

export { RELAY_SCREEN_FRAME_FRESH_MS };

/**
 * `frozen` is a stream that rendered before and then stopped receiving
 * frames; `stalled` is a stream that never rendered at all.
 */
export type ScreenVideoRenderPhase = 'idle' | 'syncing' | 'ready' | 'frozen' | 'stalled' | 'error';

export type ScreenVideoTone = 'ok' | 'warning' | 'error';

export interface ScreenVideoStatus {
  label: string;
  tone: ScreenVideoTone;
  canControl: boolean;
  issue:
    | 'off'
    | 'offline'
    | 'capture'
    | 'disconnected'
    | 'waiting'
    | 'syncing'
    | 'frozen'
    | 'stalled'
    | 'video-error'
    | 'ready';
}

export interface ScreenVideoStatusInput {
  screenEnabled: boolean;
  hostOnline: boolean | null;
  captureError: string | null;
  connectionError: string | null;
  hasStream: boolean;
  renderPhase: ScreenVideoRenderPhase;
}

export const SCREEN_VIDEO_ELEMENT_EVENTS = [
  'loadedmetadata',
  'loadeddata',
  'canplay',
  'playing',
  'resize',
  'timeupdate',
  'waiting',
  'stalled',
  'error',
] as const satisfies readonly (keyof HTMLVideoElementEventMap)[];

export type ScreenVideoElementEvent = (typeof SCREEN_VIDEO_ELEMENT_EVENTS)[number];

export function hasRenderableVideoFrame(video: Pick<HTMLVideoElement, 'videoWidth' | 'videoHeight' | 'readyState'>): boolean {
  return video.videoWidth > 0 && video.videoHeight > 0 && video.readyState >= 2;
}

export function hasFreshRelayScreenFrame(
  frame: { atUnixMs: number } | null | undefined,
  nowUnixMs: number,
): boolean {
  return hasFreshRelayScreenFrameTimestamp(frame, nowUnixMs);
}

export function isScreenDisconnectedError(message: string | null): boolean {
  if (!message) return false;
  const lower = message.toLowerCase();
  return lower.includes('screen stream disconnected') || lower.includes('screen disconnected');
}

export function describeScreenVideoStatus(input: ScreenVideoStatusInput): ScreenVideoStatus {
  if (!input.screenEnabled) {
    return { label: 'Screen sharing off', tone: 'warning', canControl: false, issue: 'off' };
  }
  if (input.hostOnline === false) {
    return { label: 'Mac offline', tone: 'error', canControl: false, issue: 'offline' };
  }
  // A picture that is rendering right now outranks error text that may be
  // stale (a status the Mac published for the fallback, a message from a
  // previous flow); the liveness watchdog demotes it the moment frames stop.
  if (input.hasStream && input.renderPhase === 'ready') {
    return { label: 'Screen ready', tone: 'ok', canControl: true, issue: 'ready' };
  }
  if (input.captureError) {
    return { label: 'Screen error', tone: 'error', canControl: false, issue: 'capture' };
  }
  if (isScreenDisconnectedError(input.connectionError)) {
    return { label: 'Screen disconnected', tone: 'error', canControl: false, issue: 'disconnected' };
  }
  if (!input.hasStream) {
    return { label: 'Waiting for screen', tone: 'warning', canControl: false, issue: 'waiting' };
  }
  if (input.renderPhase === 'frozen') {
    return { label: 'Screen paused', tone: 'warning', canControl: false, issue: 'frozen' };
  }
  if (input.renderPhase === 'stalled') {
    return { label: 'Screen not visible', tone: 'error', canControl: false, issue: 'stalled' };
  }
  if (input.renderPhase === 'error') {
    return { label: 'Screen error', tone: 'error', canControl: false, issue: 'video-error' };
  }
  return { label: 'Syncing video', tone: 'warning', canControl: false, issue: 'syncing' };
}
