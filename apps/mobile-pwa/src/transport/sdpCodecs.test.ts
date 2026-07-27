import { describe, expect, it } from 'vitest';
import { preferH264InAnswerSdp } from './sdpCodecs';

describe('preferH264InAnswerSdp', () => {
  it('moves H.264 payloads ahead of VP8 in the video media line', () => {
    const sdp = [
      'v=0',
      'o=- 1 1 IN IP4 127.0.0.1',
      's=-',
      't=0 0',
      'm=video 9 UDP/TLS/RTP/SAVPF 96 97 102 103',
      'a=rtpmap:96 VP8/90000',
      'a=rtpmap:97 rtx/90000',
      'a=fmtp:97 apt=96',
      'a=rtpmap:102 H264/90000',
      'a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f',
      'a=rtpmap:103 rtx/90000',
      'a=fmtp:103 apt=102',
      '',
    ].join('\r\n');

    expect(preferH264InAnswerSdp(sdp)).toContain('m=video 9 UDP/TLS/RTP/SAVPF 102 103 96 97');
  });

  it('prefers packetization-mode 1 H.264 when multiple H.264 payloads exist', () => {
    const sdp = [
      'v=0',
      'm=video 9 UDP/TLS/RTP/SAVPF 96 100 101 102 103',
      'a=rtpmap:96 VP8/90000',
      'a=rtpmap:100 H264/90000',
      'a=fmtp:100 level-asymmetry-allowed=1;profile-level-id=42e01f',
      'a=rtpmap:101 rtx/90000',
      'a=fmtp:101 apt=100',
      'a=rtpmap:102 H264/90000',
      'a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f',
      'a=rtpmap:103 rtx/90000',
      'a=fmtp:103 apt=102',
      '',
    ].join('\n');

    expect(preferH264InAnswerSdp(sdp)).toContain('m=video 9 UDP/TLS/RTP/SAVPF 102 100 103 101 96');
  });

  it('leaves SDP unchanged when the video section has no H.264 codec', () => {
    const sdp = [
      'v=0',
      'm=video 9 UDP/TLS/RTP/SAVPF 96 97',
      'a=rtpmap:96 VP8/90000',
      'a=rtpmap:97 rtx/90000',
      'a=fmtp:97 apt=96',
      '',
    ].join('\n');

    expect(preferH264InAnswerSdp(sdp)).toBe(sdp);
  });
});
