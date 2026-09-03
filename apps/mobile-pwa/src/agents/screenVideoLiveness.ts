/**
 * Frame-liveness watchdog for the Mac Screen video.
 *
 * A WebRTC connection stays "connected" while ICE consent flows, even when the
 * Mac stopped sending frames (a dead capture, a track removed on the Mac, a
 * suspended tab). Safari paints such a track black and Chrome freezes it, and
 * `videoWidth`/`readyState` keep reporting a renderable element. The only
 * reliable signal is frame progress: decoded frames from `getStats()` and
 * painted frames from `requestVideoFrameCallback`.
 */

export const LIVENESS_SAMPLE_MS = 1_000;
/** A fresh track always carries a keyframe; silence this long means the flow is dead. */
export const FIRST_FRAME_TIMEOUT_MS = 10_000;
/** Strict mode only: no frame for this long shows "Screen paused". */
export const STALL_AFTER_MS = 5_000;
/** Strict mode only: no frame for this long restarts the stream. */
export const RESTART_AFTER_MS = 12_000;
/** Extra wait before each further restart of a stream that keeps stalling. */
export const RESTART_BACKOFF_MS = [0, 10_000, 20_000, 40_000, 60_000] as const;
/** A stream that stayed live this long after attach resets the restart backoff. */
export const LIVE_RESET_MS = 15_000;
/**
 * Hosts from this version repeat the last captured frame at least once per
 * second while the screen is idle, so a quiet stream is a dead stream. Older
 * hosts go silent on a static screen, which is indistinguishable from a stall.
 */
export const FRAME_KEEPALIVE_MIN_HOST_VERSION = '0.2.3';

export type ScreenVideoLivenessState = 'starting' | 'live' | 'stalled';

export interface ScreenVideoLivenessSample {
  atMs: number;
  /** Sum of `inbound-rtp` video `framesDecoded`, or null when stats are unavailable. */
  framesDecoded: number | null;
  /** Frames painted by the element, or null when the browser lacks the callback. */
  paintedFrames: number | null;
  trackLive: boolean;
}

export interface ScreenVideoLivenessVerdict {
  state: ScreenVideoLivenessState;
  /** Time since the last frame progress (since attach while starting). */
  quietMs: number;
  restart: boolean;
}

export interface ScreenVideoLivenessOptions {
  /** The host guarantees a minimum frame cadence (see FRAME_KEEPALIVE_MIN_HOST_VERSION). */
  strict: boolean;
  firstFrameTimeoutMs?: number;
  stallAfterMs?: number;
  restartAfterMs?: number;
}

export class ScreenVideoLivenessTracker {
  private readonly firstFrameTimeoutMs: number;
  private readonly stallAfterMs: number;
  private readonly restartAfterMs: number;
  private readonly strict: boolean;
  private lastProgressAtMs: number;
  private hasFrames = false;
  private lastDecoded: number | null = null;
  private lastPainted: number | null = null;
  private paused = false;

  constructor(options: ScreenVideoLivenessOptions, attachedAtMs: number) {
    this.strict = options.strict;
    this.firstFrameTimeoutMs = options.firstFrameTimeoutMs ?? FIRST_FRAME_TIMEOUT_MS;
    this.stallAfterMs = options.stallAfterMs ?? STALL_AFTER_MS;
    this.restartAfterMs = options.restartAfterMs ?? RESTART_AFTER_MS;
    this.lastProgressAtMs = attachedAtMs;
  }

  /** A hidden page decodes nothing; quiet time while hidden is not a stall. */
  pause(): void {
    this.paused = true;
  }

  resume(atMs: number): void {
    if (!this.paused) return;
    this.paused = false;
    this.lastProgressAtMs = atMs;
  }

  observe(sample: ScreenVideoLivenessSample): ScreenVideoLivenessVerdict {
    const progressed =
      advanced(this.lastDecoded, sample.framesDecoded) ||
      advanced(this.lastPainted, sample.paintedFrames);
    if (sample.framesDecoded !== null) this.lastDecoded = sample.framesDecoded;
    if (sample.paintedFrames !== null) this.lastPainted = sample.paintedFrames;
    if (progressed) {
      this.lastProgressAtMs = sample.atMs;
      this.hasFrames = true;
    }

    if (!sample.trackLive) {
      return { state: 'stalled', quietMs: Math.max(0, sample.atMs - this.lastProgressAtMs), restart: true };
    }
    if (this.paused) {
      return { state: this.hasFrames ? 'live' : 'starting', quietMs: 0, restart: false };
    }

    const quietMs = Math.max(0, sample.atMs - this.lastProgressAtMs);
    if (!this.hasFrames) {
      return { state: 'starting', quietMs, restart: quietMs >= this.firstFrameTimeoutMs };
    }
    if (!this.strict) {
      // Without keepalive frames a static screen and a dead stream look alike.
      return { state: 'live', quietMs, restart: false };
    }
    if (quietMs >= this.restartAfterMs) {
      return { state: 'stalled', quietMs, restart: true };
    }
    if (quietMs >= this.stallAfterMs) {
      return { state: 'stalled', quietMs, restart: false };
    }
    return { state: 'live', quietMs, restart: false };
  }
}

function advanced(previous: number | null, next: number | null): boolean {
  if (next === null) return false;
  if (previous === null) return next > 0;
  return next > previous;
}

export function restartBackoffMs(attempt: number): number {
  const index = Math.max(0, Math.min(attempt, RESTART_BACKOFF_MS.length - 1));
  return RESTART_BACKOFF_MS[index];
}

export function hostSupportsFrameKeepalive(hostVersion: string | null | undefined): boolean {
  return compareVersions(hostVersion, FRAME_KEEPALIVE_MIN_HOST_VERSION) >= 0;
}

/** Compares dotted numeric versions; anything unparsable sorts below every version. */
export function compareVersions(left: string | null | undefined, right: string): number {
  const a = parseVersion(left);
  const b = parseVersion(right);
  if (!a) return -1;
  if (!b) return 1;
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    const diff = (a[index] ?? 0) - (b[index] ?? 0);
    if (diff !== 0) return diff < 0 ? -1 : 1;
  }
  return 0;
}

function parseVersion(value: string | null | undefined): number[] | null {
  const match = value?.trim().match(/^v?(\d+(?:\.\d+)*)/);
  if (!match) return null;
  return match[1].split('.').map((part) => Number.parseInt(part, 10));
}

export function inboundVideoFramesDecoded(report: RTCStatsReport): number | null {
  let total = 0;
  let found = false;
  report.forEach((stat) => {
    const record = stat as Record<string, unknown>;
    const kind = record.kind ?? record.mediaType;
    if (record.type !== 'inbound-rtp' || kind !== 'video' || record.isRemote === true) return;
    found = true;
    const frames = record.framesDecoded;
    if (typeof frames === 'number' && Number.isFinite(frames)) total += frames;
  });
  return found ? total : null;
}
