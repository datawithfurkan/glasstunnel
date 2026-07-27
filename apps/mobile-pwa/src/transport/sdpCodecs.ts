export function preferH264InAnswerSdp(sdp: string): string {
  const sections = splitSdpSections(sdp);
  const rewritten = sections.map((section) => (isVideoSection(section) ? preferH264InVideoSection(section) : section));
  return rewritten.join('');
}

function splitSdpSections(sdp: string): string[] {
  const newline = sdp.includes('\r\n') ? '\r\n' : '\n';
  const lines = sdp.split(/\r?\n/);
  const sections: string[][] = [];
  let current: string[] = [];

  for (const line of lines) {
    if (line.startsWith('m=') && current.length > 0) {
      sections.push(current);
      current = [];
    }
    current.push(line);
  }
  if (current.length > 0) sections.push(current);

  return sections.map((section, index) => section.join(newline) + (index < sections.length - 1 ? newline : ''));
}

function isVideoSection(section: string): boolean {
  return /^m=video\s/m.test(section);
}

function preferH264InVideoSection(section: string): string {
  const newline = section.includes('\r\n') ? '\r\n' : '\n';
  const lines = section.split(/\r?\n/);
  const mediaLineIndex = lines.findIndex((line) => line.startsWith('m=video '));
  if (mediaLineIndex < 0) return section;

  const mediaParts = lines[mediaLineIndex].split(' ');
  if (mediaParts.length < 4) return section;

  const payloads = mediaParts.slice(3);
  const h264Payloads = payloads.filter((payload) => isH264Payload(lines, payload));
  if (h264Payloads.length === 0) return section;

  const preferredH264 = h264Payloads.sort((a, b) => h264PayloadRank(lines, b) - h264PayloadRank(lines, a));
  const associatedRtx = preferredH264.flatMap((payload) => rtxPayloadsForApt(lines, payload));
  const preferred = [...preferredH264, ...associatedRtx];
  const reordered = [...preferred, ...payloads.filter((payload) => !preferred.includes(payload))];

  lines[mediaLineIndex] = [...mediaParts.slice(0, 3), ...reordered].join(' ');
  return lines.join(newline);
}

function isH264Payload(lines: string[], payload: string): boolean {
  const rtpmap = lines.find((line) => line.toLowerCase().startsWith(`a=rtpmap:${payload.toLowerCase()} `));
  return /h264\/90000/i.test(rtpmap ?? '');
}

function h264PayloadRank(lines: string[], payload: string): number {
  const fmtp = lines.find((line) => line.toLowerCase().startsWith(`a=fmtp:${payload.toLowerCase()} `)) ?? '';
  let rank = 0;
  if (/packetization-mode=1/i.test(fmtp)) rank += 10;
  if (/profile-level-id=42/i.test(fmtp)) rank += 2;
  if (/profile-level-id=4d/i.test(fmtp)) rank += 1;
  return rank;
}

function rtxPayloadsForApt(lines: string[], aptPayload: string): string[] {
  return lines
    .filter((line) => fmtpReferencesApt(line, aptPayload))
    .map((line) => line.match(/^a=fmtp:(\d+)\s/i)?.[1])
    .filter((payload): payload is string => Boolean(payload));
}

function fmtpReferencesApt(line: string, aptPayload: string): boolean {
  const params = line.match(/^a=fmtp:\d+\s+(.+)$/i)?.[1];
  if (!params) return false;
  return params
    .split(';')
    .map((param) => param.trim())
    .some((param) => param.toLowerCase() === `apt=${aptPayload}`.toLowerCase());
}
