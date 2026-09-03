import { describe, expect, it } from 'vitest';
import {
  compareVersions,
  FIRST_FRAME_TIMEOUT_MS,
  hostSupportsFrameKeepalive,
  inboundVideoFramesDecoded,
  RESTART_AFTER_MS,
  restartBackoffMs,
  ScreenVideoLivenessTracker,
  STALL_AFTER_MS,
} from './screenVideoLiveness';

const ATTACH = 100_000;

function sample(
  atMs: number,
  framesDecoded: number | null,
  paintedFrames: number | null = null,
  trackLive = true,
) {
  return { atMs, framesDecoded, paintedFrames, trackLive };
}

describe('screen video liveness tracker', () => {
  it('reports starting until the first decoded frame, then live', () => {
    const tracker = new ScreenVideoLivenessTracker({ strict: true }, ATTACH);

    expect(tracker.observe(sample(ATTACH + 1_000, 0))).toEqual({
      state: 'starting',
      quietMs: 1_000,
      restart: false,
    });
    expect(tracker.observe(sample(ATTACH + 2_000, 3))).toEqual({
      state: 'live',
      quietMs: 0,
      restart: false,
    });
  });

  it('asks for a restart when no frame ever arrives', () => {
    const tracker = new ScreenVideoLivenessTracker({ strict: false }, ATTACH);

    expect(tracker.observe(sample(ATTACH + FIRST_FRAME_TIMEOUT_MS - 1, 0)).restart).toBe(false);
    expect(tracker.observe(sample(ATTACH + FIRST_FRAME_TIMEOUT_MS, 0))).toEqual({
      state: 'starting',
      quietMs: FIRST_FRAME_TIMEOUT_MS,
      restart: true,
    });
  });

  it('marks a strict stream stalled, then restarts it, when frames stop', () => {
    const tracker = new ScreenVideoLivenessTracker({ strict: true }, ATTACH);
    tracker.observe(sample(ATTACH + 1_000, 10));

    expect(tracker.observe(sample(ATTACH + 1_000 + STALL_AFTER_MS - 1, 10)).state).toBe('live');
    expect(tracker.observe(sample(ATTACH + 1_000 + STALL_AFTER_MS, 10))).toEqual({
      state: 'stalled',
      quietMs: STALL_AFTER_MS,
      restart: false,
    });
    expect(tracker.observe(sample(ATTACH + 1_000 + RESTART_AFTER_MS, 10))).toEqual({
      state: 'stalled',
      quietMs: RESTART_AFTER_MS,
      restart: true,
    });
  });

  it('recovers to live as soon as frames resume', () => {
    const tracker = new ScreenVideoLivenessTracker({ strict: true }, ATTACH);
    tracker.observe(sample(ATTACH + 1_000, 10));
    expect(tracker.observe(sample(ATTACH + 8_000, 10)).state).toBe('stalled');

    expect(tracker.observe(sample(ATTACH + 9_000, 11))).toEqual({
      state: 'live',
      quietMs: 0,
      restart: false,
    });
  });

  it('never restarts a quiet stream from an older host without keepalive frames', () => {
    const tracker = new ScreenVideoLivenessTracker({ strict: false }, ATTACH);
    tracker.observe(sample(ATTACH + 1_000, 10));

    const later = tracker.observe(sample(ATTACH + 120_000, 10));
    expect(later.state).toBe('live');
    expect(later.restart).toBe(false);
    expect(later.quietMs).toBe(119_000);
  });

  it('counts painted frames as progress when stats are unavailable', () => {
    const tracker = new ScreenVideoLivenessTracker({ strict: true }, ATTACH);

    expect(tracker.observe(sample(ATTACH + 1_000, null, 1)).state).toBe('live');
    expect(tracker.observe(sample(ATTACH + 3_000, null, 4)).quietMs).toBe(0);
    expect(tracker.observe(sample(ATTACH + 9_000, null, 4)).state).toBe('stalled');
  });

  it('ignores quiet time while the page is hidden', () => {
    const tracker = new ScreenVideoLivenessTracker({ strict: true }, ATTACH);
    tracker.observe(sample(ATTACH + 1_000, 10));
    tracker.pause();

    expect(tracker.observe(sample(ATTACH + 60_000, 10))).toEqual({
      state: 'live',
      quietMs: 0,
      restart: false,
    });

    tracker.resume(ATTACH + 61_000);
    expect(tracker.observe(sample(ATTACH + 62_000, 10)).state).toBe('live');
    expect(tracker.observe(sample(ATTACH + 61_000 + RESTART_AFTER_MS, 10)).restart).toBe(true);
  });

  it('restarts immediately once the track has ended', () => {
    const tracker = new ScreenVideoLivenessTracker({ strict: false }, ATTACH);
    tracker.observe(sample(ATTACH + 1_000, 10));

    expect(tracker.observe(sample(ATTACH + 2_000, 10, null, false)).restart).toBe(true);
  });
});

describe('screen video liveness helpers', () => {
  it('grows the restart wait and caps it', () => {
    expect(restartBackoffMs(0)).toBe(0);
    expect(restartBackoffMs(1)).toBe(10_000);
    expect(restartBackoffMs(2)).toBe(20_000);
    expect(restartBackoffMs(40)).toBe(60_000);
  });

  it('enables strict liveness only for hosts that repeat idle frames', () => {
    expect(hostSupportsFrameKeepalive('0.2.2')).toBe(false);
    expect(hostSupportsFrameKeepalive('0.2.3')).toBe(true);
    expect(hostSupportsFrameKeepalive('0.3.0')).toBe(true);
    expect(hostSupportsFrameKeepalive('1.0')).toBe(true);
    expect(hostSupportsFrameKeepalive(undefined)).toBe(false);
    expect(hostSupportsFrameKeepalive('dev')).toBe(false);
  });

  it('compares dotted versions numerically', () => {
    expect(compareVersions('0.2.10', '0.2.9')).toBe(1);
    expect(compareVersions('0.2', '0.2.0')).toBe(0);
    expect(compareVersions('v0.2.3', '0.2.3')).toBe(0);
    expect(compareVersions(null, '0.0.1')).toBe(-1);
  });

  it('sums decoded frames over inbound video streams only', () => {
    const report = new Map<string, Record<string, unknown>>([
      ['a', { type: 'inbound-rtp', kind: 'video', framesDecoded: 12 }],
      ['b', { type: 'inbound-rtp', mediaType: 'video', framesDecoded: 3 }],
      ['c', { type: 'inbound-rtp', kind: 'audio', framesDecoded: 99 }],
      ['d', { type: 'outbound-rtp', kind: 'video', framesDecoded: 99 }],
    ]) as unknown as RTCStatsReport;

    expect(inboundVideoFramesDecoded(report)).toBe(15);
    expect(inboundVideoFramesDecoded(new Map() as unknown as RTCStatsReport)).toBeNull();
  });
});
