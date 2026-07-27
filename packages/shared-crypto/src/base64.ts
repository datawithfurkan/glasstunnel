interface GlobalWithEncoding {
  Buffer?: {
    from: (v: Uint8Array | string, enc?: string) => { toString: (enc: string) => string } & Uint8Array;
  };
  btoa?: (s: string) => string;
  atob?: (s: string) => string;
}

export function base64FromBytes(bytes: Uint8Array): string {
  const g = globalThis as unknown as GlobalWithEncoding;
  if (g.Buffer) return g.Buffer.from(bytes).toString('base64');
  let binary = '';
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return g.btoa ? g.btoa(binary) : '';
}

export function bytesFromBase64(b64: string): Uint8Array {
  const g = globalThis as unknown as GlobalWithEncoding;
  if (g.Buffer) return new Uint8Array(g.Buffer.from(b64, 'base64'));
  const binary = g.atob ? g.atob(b64) : '';
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function hex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

export function fromHex(s: string): Uint8Array {
  if (s.length % 2 !== 0) throw new Error('hex string must be even length');
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(s.substr(i * 2, 2), 16);
  }
  return out;
}
