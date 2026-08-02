import { exports } from 'cloudflare:workers';
import { describe, expect, it } from 'vitest';

async function fetchWorker(path: string, init?: RequestInit): Promise<Response> {
  return exports.default.fetch(new Request(`https://worker.test${path}`, init));
}

const allowedOrigin = 'http://127.0.0.1:5173';

describe('Glasstunnel signaling Worker', () => {
  it('reports a healthy local Worker runtime', async () => {
    const response = await fetchWorker('/health');

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      ok: true,
      service: 'glasstunnel-signal-worker',
    });
  });

  it('returns a structured 404 for unknown routes', async () => {
    const response = await fetchWorker('/does-not-exist');

    expect(response.status).toBe(404);
    await expect(response.json()).resolves.toEqual({ ok: false, error: 'not found' });
  });

  it('returns exact CORS headers to the configured browser origin', async () => {
    const response = await fetchWorker('/health', {
      headers: { origin: allowedOrigin },
    });

    expect(response.status).toBe(200);
    expect(response.headers.get('access-control-allow-origin')).toBe(allowedOrigin);
    expect(response.headers.get('vary')).toContain('Origin');
  });

  it('rejects browser requests from an unconfigured origin', async () => {
    const response = await fetchWorker('/health', {
      headers: { origin: 'https://attacker.example' },
    });

    expect(response.status).toBe(403);
    expect(response.headers.get('access-control-allow-origin')).toBeNull();
    await expect(response.json()).resolves.toEqual({
      ok: false,
      error: 'origin not allowed',
    });
  });

  it('allows native clients that do not send an Origin header', async () => {
    const response = await fetchWorker('/health');

    expect(response.status).toBe(200);
    expect(response.headers.get('access-control-allow-origin')).toBeNull();
  });

  it('answers allowed preflight requests without forwarding them', async () => {
    const response = await fetchWorker('/account/device/register', {
      method: 'OPTIONS',
      headers: {
        origin: allowedOrigin,
        'access-control-request-method': 'POST',
        'access-control-request-headers': 'authorization,content-type',
      },
    });

    expect(response.status).toBe(204);
    expect(response.headers.get('access-control-allow-origin')).toBe(allowedOrigin);
    expect(response.headers.get('access-control-allow-methods')).toBe('GET, POST, OPTIONS');
  });

  it('rejects relay requests without a host device id', async () => {
    const response = await fetchWorker('/relay');

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toEqual({
      ok: false,
      error: 'host_device_id is required',
    });
  });

  it('rejects account registration without a bearer token', async () => {
    const response = await fetchWorker('/account/device/register', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({}),
    });

    expect(response.status).toBe(401);
    await expect(response.json()).resolves.toEqual({
      ok: false,
      error: 'missing bearer token',
    });
  });

  it('rate limits repeated account attempts by the same unauthenticated client', async () => {
    const request = () => fetchWorker('/account/device/register', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'cf-connecting-ip': '198.51.100.24',
      },
      body: JSON.stringify({}),
    });

    expect((await request()).status).toBe(401);
    expect((await request()).status).toBe(401);
    const limited = await request();

    expect(limited.status).toBe(429);
    expect(limited.headers.get('retry-after')).toBe('60');
    await expect(limited.json()).resolves.toEqual({
      ok: false,
      error: 'too many requests',
    });
  });

  it('rate limits token rotation by the same connecting address', async () => {
    const request = (attempt: number) => fetchWorker('/account/device/register', {
      method: 'POST',
      headers: {
        authorization: `Bearer invalid-token-${attempt}`,
        'content-type': 'application/json',
        'cf-connecting-ip': '198.51.100.25',
      },
      body: JSON.stringify({}),
    });

    for (let attempt = 1; attempt <= 4; attempt += 1) {
      expect((await request(attempt)).status).not.toBe(429);
    }
    expect((await request(5)).status).toBe(429);
  });
});
