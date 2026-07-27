import { describe, expect, it } from 'vitest';
import {
  compactRelayAgentSnapshot,
  serializedRelayAgentSnapshotBytes,
  type CacheJsonValue,
} from '../src/relaySnapshotCache';

describe('relay snapshot persistence cache', () => {
  it('keeps oversized agent history below the durable-object value limit', () => {
    const snapshot: Record<string, CacheJsonValue> = {
      agentId: 'codex',
      agentLabel: 'Codex',
      adapterKind: 1,
      status: 1,
      statusDetail: 'working',
      recentMessages: Array.from({ length: 250 }, (_, index) => ({
        messageId: `message-${index}`,
        role: 1,
        text: `${index}:${'x'.repeat(16 * 1024)}`,
        atUnixMs: index,
        redacted: false,
        pendingToolCalls: [],
      })),
      lastActivityUnixMs: 250,
      position: { row: 0, col: 0, rowSpan: 1, colSpan: 1 },
      hasVideoTrack: false,
      availableTargets: Array.from({ length: 100 }, (_, index) => ({
        targetId: `target-${index}`,
        label: `Target ${index}`,
        subtitle: 'x'.repeat(8 * 1024),
        selected: index === 99,
      })),
    };

    const compacted = compactRelayAgentSnapshot(snapshot);
    const messages = compacted.recentMessages as Array<Record<string, CacheJsonValue>>;

    expect(serializedRelayAgentSnapshotBytes(compacted)).toBeLessThanOrEqual(96 * 1024);
    expect(messages.length).toBeGreaterThanOrEqual(4);
    expect(messages.length).toBeLessThanOrEqual(20);
    expect(messages.at(-1)?.messageId).toBe('message-249');
    expect((compacted.availableTargets as CacheJsonValue[]).length).toBeLessThanOrEqual(40);
  });

  it('drops oversized nested runtime controls from the minimal fallback', () => {
    const snapshot: Record<string, CacheJsonValue> = {
      agentId: 'screen',
      runtimeControls: Object.fromEntries(
        Array.from({ length: 100 }, (_, index) => [
          `control-${index}`,
          Array.from({ length: 50 }, () => 'x'.repeat(8 * 1024)),
        ]),
      ),
    };

    const compacted = compactRelayAgentSnapshot(snapshot);

    expect(serializedRelayAgentSnapshotBytes(compacted)).toBeLessThanOrEqual(96 * 1024);
    expect(compacted.runtimeControls).toBeUndefined();
  });

  it('guarantees the cache limit when normally scalar fields contain nested data', () => {
    const oversizedValue = Array.from({ length: 50 }, () => 'x'.repeat(8 * 1024));
    const snapshot: Record<string, CacheJsonValue> = {
      agentId: oversizedValue,
      agentLabel: oversizedValue,
      adapterKind: oversizedValue,
      status: oversizedValue,
      statusDetail: oversizedValue,
      position: oversizedValue,
      lastActivityUnixMs: oversizedValue,
      hasVideoTrack: oversizedValue,
      remoteAppId: oversizedValue,
      runtimeControls: oversizedValue,
    };

    const compacted = compactRelayAgentSnapshot(snapshot);

    expect(serializedRelayAgentSnapshotBytes(compacted)).toBeLessThanOrEqual(96 * 1024);
    expect(compacted.agentId).toBe('');
    expect(compacted.recentMessages).toEqual([]);
    expect(compacted.availableTargets).toEqual([]);
  });
});
