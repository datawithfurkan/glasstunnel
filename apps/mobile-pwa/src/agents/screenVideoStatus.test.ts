import { describe, expect, it } from 'vitest';
import {
  describeScreenVideoStatus,
  hasFreshRelayScreenFrame,
  hasRenderableVideoFrame,
  isScreenDisconnectedError,
  SCREEN_VIDEO_ELEMENT_EVENTS,
} from './screenVideoStatus';

describe('screen video status', () => {
  it('does not call a stream live until a rendered frame is available', () => {
    const status = describeScreenVideoStatus({
      screenEnabled: true,
      hostOnline: true,
      captureError: null,
      connectionError: null,
      hasStream: true,
      renderPhase: 'syncing',
    });

    expect(status.label).toBe('Syncing video');
    expect(status.tone).toBe('warning');
    expect(status.canControl).toBe(false);
  });

  it('allows screen control only after the video element can render a frame', () => {
    const status = describeScreenVideoStatus({
      screenEnabled: true,
      hostOnline: true,
      captureError: null,
      connectionError: null,
      hasStream: true,
      renderPhase: 'ready',
    });

    expect(status.label).toBe('Screen ready');
    expect(status.tone).toBe('ok');
    expect(status.canControl).toBe(true);
  });

  it('prioritizes screen disconnection over stale streams', () => {
    const status = describeScreenVideoStatus({
      screenEnabled: true,
      hostOnline: true,
      captureError: null,
      connectionError: 'Screen stream disconnected. Retry screen to reconnect.',
      hasStream: true,
      renderPhase: 'ready',
    });

    expect(status.label).toBe('Screen disconnected');
    expect(status.tone).toBe('error');
    expect(status.canControl).toBe(false);
  });

  it('shows an off state when screen sharing is disabled remotely', () => {
    const status = describeScreenVideoStatus({
      screenEnabled: false,
      hostOnline: true,
      captureError: null,
      connectionError: null,
      hasStream: true,
      renderPhase: 'ready',
    });

    expect(status.label).toBe('Screen sharing off');
    expect(status.tone).toBe('warning');
    expect(status.canControl).toBe(false);
  });

  it('checks the browser video element readiness and dimensions', () => {
    expect(hasRenderableVideoFrame({ videoWidth: 0, videoHeight: 0, readyState: 4 })).toBe(false);
    expect(hasRenderableVideoFrame({ videoWidth: 1280, videoHeight: 720, readyState: 1 })).toBe(false);
    expect(hasRenderableVideoFrame({ videoWidth: 1280, videoHeight: 720, readyState: 2 })).toBe(true);
  });

  it('accepts relay frames only while they are current', () => {
    const now = 10_000;

    expect(hasFreshRelayScreenFrame(undefined, now)).toBe(false);
    expect(hasFreshRelayScreenFrame({ atUnixMs: now - 5_999 }, now)).toBe(true);
    expect(hasFreshRelayScreenFrame({ atUnixMs: now - 6_000 }, now)).toBe(false);
    expect(hasFreshRelayScreenFrame({ atUnixMs: now + 30_001 }, now)).toBe(false);
  });

  it('does not enable control from a stale relay frame', () => {
    const now = 10_000;
    const hasStream = hasFreshRelayScreenFrame({ atUnixMs: now - 6_000 }, now);
    const status = describeScreenVideoStatus({
      screenEnabled: true,
      hostOnline: true,
      captureError: null,
      connectionError: null,
      hasStream,
      renderPhase: hasStream ? 'ready' : 'idle',
    });

    expect(status.label).toBe('Waiting for screen');
    expect(status.canControl).toBe(false);
  });

  it('recognizes screen-specific disconnect messages', () => {
    expect(isScreenDisconnectedError('Screen stream disconnected. Retry screen to reconnect.')).toBe(true);
    expect(isScreenDisconnectedError('Connection dropped. Reconnecting automatically...')).toBe(false);
  });

  it('does not treat media-element detach events as stream-ending events', () => {
    expect(SCREEN_VIDEO_ELEMENT_EVENTS).not.toContain('emptied');
  });
});
