import type { RelayHub, SignalingHub } from '../../apps/cloudflare-signal/src/index';

interface Bindings {
  RELAY_HUB: DurableObjectNamespace<RelayHub>;
  SIGNALING_HUB: DurableObjectNamespace<SignalingHub>;
  OPERATOR_TOKEN: string;
}

export default {
  async fetch(request: Request, env: Bindings): Promise<Response> {
    if (!env.OPERATOR_TOKEN || request.headers.get('Authorization') !== `Bearer ${env.OPERATOR_TOKEN}`) {
      return new Response('Forbidden', { status: 403 });
    }
    if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 });
    try {
      const raw = await request.text();
      if (raw.length > 4096) return new Response('Too large', { status: 413 });
      const body = JSON.parse(raw) as { namespace?: string; id?: string; dryRun?: boolean; cursor?: string };
      if (!['relay', 'signal'].includes(body.namespace ?? '') ||
        typeof body.id !== 'string' || !/^[a-f0-9]{64}$/.test(body.id) || typeof body.dryRun !== 'boolean' ||
        (body.cursor !== undefined && typeof body.cursor !== 'string')) {
        return new Response('Invalid operation', { status: 400 });
      }
      const binding = body.namespace === 'relay' ? env.RELAY_HUB : env.SIGNALING_HUB;
      const stub = binding.get(binding.idFromString(body.id));
      return Response.json(await stub.cacheMaintenance({ dryRun: body.dryRun, cursor: body.cursor }), { headers: { 'Cache-Control': 'no-store' } });
    } catch {
      return new Response('Maintenance unavailable', { status: 503 });
    }
  },
};
