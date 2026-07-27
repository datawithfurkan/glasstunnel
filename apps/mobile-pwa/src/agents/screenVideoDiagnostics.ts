import { hasRenderableVideoFrame } from './screenVideoStatus';

export type ScreenVideoDiagnosticIssue =
  | 'no-peer'
  | 'no-live-track'
  | 'no-inbound-stats'
  | 'waiting-for-bytes'
  | 'decode-stalled'
  | 'render-stalled'
  | 'receiving';

export interface ScreenVideoDiagnostics {
  issue: ScreenVideoDiagnosticIssue;
  detail: string;
  bytesReceived: number;
  framesDecoded: number;
  framesRendered: number;
  framesDropped: number;
  codec: string | null;
}

interface VideoState {
  videoWidth: number;
  videoHeight: number;
  readyState: number;
}

interface DiagnosticInput {
  hasLiveVideoTrack: boolean;
  video: VideoState;
  stats: readonly Record<string, unknown>[];
}

interface InboundVideoSummary {
  bytesReceived: number;
  framesDecoded: number;
  framesRendered: number;
  framesDropped: number;
  codec: string | null;
  hasInboundVideoStats: boolean;
}

export async function collectScreenVideoDiagnostics(
  pc: RTCPeerConnection | null,
  stream: MediaStream | null,
  video: VideoState,
): Promise<ScreenVideoDiagnostics> {
  if (!pc) {
    return emptyDiagnostics('no-peer', 'The screen peer connection is not ready yet.');
  }

  const report = await pc.getStats();
  return describeScreenVideoDiagnostics({
    hasLiveVideoTrack: Boolean(
      stream?.getVideoTracks().some((track) => track.readyState === 'live'),
    ),
    video,
    stats: statsReportValues(report),
  });
}

export function describeScreenVideoDiagnostics(input: DiagnosticInput): ScreenVideoDiagnostics {
  if (!input.hasLiveVideoTrack) {
    return emptyDiagnostics(
      'no-live-track',
      'The browser attached a stream, but no live screen track is present yet.',
    );
  }

  const summary = summarizeInboundVideo(input.stats);
  if (!summary.hasInboundVideoStats) {
    return {
      issue: 'no-inbound-stats',
      detail:
        'The WebRTC screen route has not received media yet. This usually means the phone needs a relay/TURN route.',
      ...summary,
    };
  }

  if (summary.bytesReceived <= 0) {
    return {
      issue: 'waiting-for-bytes',
      detail: withMetrics('No screen video bytes have arrived on this phone yet.', summary),
      ...summary,
    };
  }

  if (summary.framesDecoded <= 0) {
    return {
      issue: 'decode-stalled',
      detail: withMetrics(
        'Screen video bytes are arriving, but this phone has decoded 0 frames. This points to codec or frame-size compatibility.',
        summary,
      ),
      ...summary,
    };
  }

  if (!hasRenderableVideoFrame(input.video)) {
    return {
      issue: 'render-stalled',
      detail: withMetrics(
        'This phone decoded screen frames, but the browser video element has not rendered them yet.',
        summary,
      ),
      ...summary,
    };
  }

  return {
    issue: 'receiving',
    detail: withMetrics('Screen video is arriving and rendering.', summary),
    ...summary,
  };
}

function summarizeInboundVideo(stats: readonly Record<string, unknown>[]): InboundVideoSummary {
  const inbound = stats.filter(isInboundVideoStat);
  const firstInbound = inbound[0];
  const codecId = typeof firstInbound?.codecId === 'string' ? firstInbound.codecId : null;
  const codec = codecId ? codecLabel(stats.find((stat) => stat.id === codecId)) : null;

  return {
    bytesReceived: sumNumber(inbound, 'bytesReceived'),
    framesDecoded: sumNumber(inbound, 'framesDecoded'),
    framesRendered: sumNumber(inbound, 'framesRendered'),
    framesDropped: sumNumber(inbound, 'framesDropped'),
    codec,
    hasInboundVideoStats: inbound.length > 0,
  };
}

function isInboundVideoStat(stat: Record<string, unknown>): boolean {
  const type = stat.type;
  const kind = stat.kind ?? stat.mediaType;
  const isRemote = stat.isRemote;
  return type === 'inbound-rtp' && kind === 'video' && isRemote !== true;
}

function codecLabel(stat: Record<string, unknown> | undefined): string | null {
  if (!stat || stat.type !== 'codec') return null;
  const mimeType = typeof stat.mimeType === 'string' ? stat.mimeType : null;
  const fmtpLine = typeof stat.sdpFmtpLine === 'string' ? stat.sdpFmtpLine : null;
  if (!mimeType) return null;
  return fmtpLine ? `${mimeType} ${fmtpLine}` : mimeType;
}

function sumNumber(stats: readonly Record<string, unknown>[], key: string): number {
  return stats.reduce((total, stat) => {
    const value = stat[key];
    return total + (typeof value === 'number' && Number.isFinite(value) ? value : 0);
  }, 0);
}

function withMetrics(message: string, summary: InboundVideoSummary): string {
  const metrics = [
    summary.codec ? `codec ${summary.codec}` : null,
    `${summary.bytesReceived} bytes`,
    `${summary.framesDecoded} decoded`,
    summary.framesDropped > 0 ? `${summary.framesDropped} dropped` : null,
  ].filter((item): item is string => Boolean(item));
  return `${message} (${metrics.join(', ')})`;
}

function emptyDiagnostics(
  issue: ScreenVideoDiagnosticIssue,
  detail: string,
): ScreenVideoDiagnostics {
  return {
    issue,
    detail,
    bytesReceived: 0,
    framesDecoded: 0,
    framesRendered: 0,
    framesDropped: 0,
    codec: null,
  };
}

function statsReportValues(report: RTCStatsReport): Record<string, unknown>[] {
  const values: Record<string, unknown>[] = [];
  report.forEach((stat) => {
    if (stat && typeof stat === 'object') {
      values.push(stat as Record<string, unknown>);
    }
  });
  return values;
}
