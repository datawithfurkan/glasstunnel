import { exports } from 'cloudflare:workers';
import { describe, expect, it } from 'vitest';

async function fetchWorker(path: string, init?: RequestInit): Promise<Response> {
  return exports.default.fetch(new Request(`https://worker.test${path}`, init));
}

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
});
