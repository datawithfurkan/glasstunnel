import {
  hasFreshRelayScreenFrameTimestamp,
  RELAY_SCREEN_FRAME_FRESH_MS,
} from '../lib/remoteApps';

export { RELAY_SCREEN_FRAME_FRESH_MS };

export type ScreenVideoRenderPhase = 'idle' | 'syncing' | 'ready' | 'stalled' | 'error';

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
  if (input.captureError) {
    return { label: 'Screen error', tone: 'error', canControl: false, issue: 'capture' };
  }
  if (isScreenDisconnectedError(input.connectionError)) {
    return { label: 'Screen disconnected', tone: 'error', canControl: false, issue: 'disconnected' };
  }
  if (!input.hasStream) {
    return { label: 'Waiting for screen', tone: 'warning', canControl: false, issue: 'waiting' };
  }
  if (input.renderPhase === 'ready') {
    return { label: 'Screen ready', tone: 'ok', canControl: true, issue: 'ready' };
  }
  if (input.renderPhase === 'stalled') {
    return { label: 'Screen not visible', tone: 'error', canControl: false, issue: 'stalled' };
  }
  if (input.renderPhase === 'error') {
    return { label: 'Screen error', tone: 'error', canControl: false, issue: 'video-error' };
  }
  return { label: 'Syncing video', tone: 'warning', canControl: false, issue: 'syncing' };
}
