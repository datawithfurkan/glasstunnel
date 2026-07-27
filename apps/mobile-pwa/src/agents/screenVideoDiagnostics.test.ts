import { describe, expect, it } from 'vitest';
import { describeScreenVideoDiagnostics } from './screenVideoDiagnostics';

const syncingVideo = { videoWidth: 0, videoHeight: 0, readyState: 1 };
const readyVideo = { videoWidth: 1280, videoHeight: 720, readyState: 2 };

describe('screen video diagnostics', () => {
  it('reports a missing live track before inspecting stats', () => {
    const diagnostics = describeScreenVideoDiagnostics({
      hasLiveVideoTrack: false,
      video: syncingVideo,
      stats: [],
    });

    expect(diagnostics.issue).toBe('no-live-track');
    expect(diagnostics.detail).toContain('no live screen track');
  });

  it('points no inbound stats at the WebRTC route instead of rendering', () => {
    const diagnostics = describeScreenVideoDiagnostics({
      hasLiveVideoTrack: true,
      video: syncingVideo,
      stats: [],
    });

    expect(diagnostics.issue).toBe('no-inbound-stats');
    expect(diagnostics.detail).toContain('needs a relay/TURN route');
  });

  it('distinguishes bytes arriving without decoded frames', () => {
    const diagnostics = describeScreenVideoDiagnostics({
      hasLiveVideoTrack: true,
      video: syncingVideo,
      stats: [
        {
          id: 'codec-1',
          type: 'codec',
          mimeType: 'video/H264',
          sdpFmtpLine: 'profile-level-id=42e01f',
        },
        {
          id: 'inbound-1',
          type: 'inbound-rtp',
          kind: 'video',
          codecId: 'codec-1',
          bytesReceived: 4096,
          framesDecoded: 0,
        },
      ],
    });

    expect(diagnostics.issue).toBe('decode-stalled');
    expect(diagnostics.detail).toContain('decoded 0 frames');
    expect(diagnostics.detail).toContain('video/H264');
  });

  it('distinguishes decoded frames from video element rendering', () => {
    const diagnostics = describeScreenVideoDiagnostics({
      hasLiveVideoTrack: true,
      video: syncingVideo,
      stats: [
        {
          id: 'inbound-1',
          type: 'inbound-rtp',
          kind: 'video',
          bytesReceived: 4096,
          framesDecoded: 3,
          framesDropped: 1,
        },
      ],
    });

    expect(diagnostics.issue).toBe('render-stalled');
    expect(diagnostics.detail).toContain('video element has not rendered');
    expect(diagnostics.framesDropped).toBe(1);
  });

  it('reports receiving once decoded frames are renderable', () => {
    const diagnostics = describeScreenVideoDiagnostics({
      hasLiveVideoTrack: true,
      video: readyVideo,
      stats: [
        {
          id: 'inbound-1',
          type: 'inbound-rtp',
          kind: 'video',
          bytesReceived: 4096,
          framesDecoded: 3,
        },
      ],
    });

    expect(diagnostics.issue).toBe('receiving');
  });
});
