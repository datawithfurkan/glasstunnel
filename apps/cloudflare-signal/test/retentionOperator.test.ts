import { describe, expect, it } from 'vitest';
import { env } from 'cloudflare:workers';
import operator from '../../../ops/cache-retention/worker';

describe('retention operator boundary', () => {
  const bindings = { RELAY_HUB: env.RELAY_HUB, SIGNALING_HUB: env.SIGNALING_HUB, OPERATOR_TOKEN: 'disposable-test-only' };
  it('denies requests without the operator capability', async () => {
    expect((await operator.fetch(new Request('https://operator.test/', { method: 'POST' }), bindings)).status).toBe(403);
  });
  it('only allows count-only inventory or scoped expiry through bound namespaces', async () => {
    const id = env.RELAY_HUB.idFromName(crypto.randomUUID()).toString();
    const request = (body: unknown) => new Request('https://operator.test/', { method: 'POST', headers: { Authorization: 'Bearer disposable-test-only' }, body: JSON.stringify(body) });
    expect((await operator.fetch(request({ namespace: 'other', id, dryRun: false }), bindings)).status).toBe(400);
    const response = await operator.fetch(request({ namespace: 'relay', id, dryRun: true }), bindings);
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ scanned: 0, invalid: 0, deleted: 0 });
  });
});
