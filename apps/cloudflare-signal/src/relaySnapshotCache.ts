const MAX_CACHED_SNAPSHOT_BYTES = 96 * 1024;
const MAX_CACHED_MESSAGES = 20;
const MAX_CACHED_TARGETS = 40;
const MAX_CACHED_STRING_LENGTH = 4 * 1024;
const MAX_CACHED_ARRAY_ITEMS = 50;
const MIN_CACHED_MESSAGES = 4;

type JsonPrimitive = string | number | boolean | null;
export type CacheJsonValue =
  | JsonPrimitive
  | CacheJsonValue[]
  | { [key: string]: CacheJsonValue };

export function compactRelayAgentSnapshot(
  snapshot: Record<string, CacheJsonValue>,
): Record<string, CacheJsonValue> {
  const compacted = compactRecord(snapshot, new Set(['recentMessages', 'availableTargets']));
  const recentMessages = compactArray(snapshot.recentMessages, MAX_CACHED_MESSAGES, true);
  const availableTargets = compactArray(snapshot.availableTargets, MAX_CACHED_TARGETS, false);

  compacted.recentMessages = recentMessages;
  if (Array.isArray(snapshot.availableTargets)) {
    compacted.availableTargets = availableTargets;
  }

  while (
    serializedBytes(compacted) > MAX_CACHED_SNAPSHOT_BYTES &&
    recentMessages.length > MIN_CACHED_MESSAGES
  ) {
    recentMessages.shift();
  }
  while (serializedBytes(compacted) > MAX_CACHED_SNAPSHOT_BYTES && availableTargets.length > 0) {
    availableTargets.pop();
  }
  while (serializedBytes(compacted) > MAX_CACHED_SNAPSHOT_BYTES && recentMessages.length > 0) {
    recentMessages.shift();
  }

  if (serializedBytes(compacted) <= MAX_CACHED_SNAPSHOT_BYTES) return compacted;

  const fallback = compactRecord({
    agentId: snapshot.agentId ?? '',
    agentLabel: snapshot.agentLabel ?? '',
    adapterKind: snapshot.adapterKind ?? 0,
    status: snapshot.status ?? 0,
    statusDetail: snapshot.statusDetail ?? '',
    recentMessages: [],
    lastActivityUnixMs: snapshot.lastActivityUnixMs ?? 0,
    position: snapshot.position ?? {},
    hasVideoTrack: snapshot.hasVideoTrack ?? false,
    availableTargets: [],
    remoteAppId: snapshot.remoteAppId ?? '',
    runtimeControls: snapshot.runtimeControls ?? null,
  });
  if (serializedBytes(fallback) <= MAX_CACHED_SNAPSHOT_BYTES) return fallback;

  delete fallback.runtimeControls;
  if (serializedBytes(fallback) <= MAX_CACHED_SNAPSHOT_BYTES) return fallback;

  return {
    agentId: compactScalar(snapshot.agentId, ''),
    agentLabel: compactScalar(snapshot.agentLabel, ''),
    adapterKind: compactScalar(snapshot.adapterKind, 0),
    status: compactScalar(snapshot.status, 0),
    statusDetail: compactScalar(snapshot.statusDetail, ''),
    recentMessages: [],
    lastActivityUnixMs: compactScalar(snapshot.lastActivityUnixMs, 0),
    hasVideoTrack: compactScalar(snapshot.hasVideoTrack, false),
    availableTargets: [],
    remoteAppId: compactScalar(snapshot.remoteAppId, ''),
  };
}

export function serializedRelayAgentSnapshotBytes(snapshot: Record<string, CacheJsonValue>): number {
  return serializedBytes(snapshot);
}

function compactArray(
  value: CacheJsonValue | undefined,
  limit: number,
  keepTail: boolean,
): CacheJsonValue[] {
  if (!Array.isArray(value)) return [];
  const selected = keepTail ? value.slice(-limit) : value.slice(0, limit);
  return selected.map((item) => compactValue(item));
}

function compactRecord(
  value: Record<string, CacheJsonValue>,
  excludedKeys: Set<string> = new Set(),
): Record<string, CacheJsonValue> {
  return Object.fromEntries(
    Object.entries(value)
      .filter(([key]) => !excludedKeys.has(key))
      .map(([key, item]) => [key, compactValue(item)]),
  );
}

function compactValue(value: CacheJsonValue): CacheJsonValue {
  if (typeof value === 'string') {
    return value.length <= MAX_CACHED_STRING_LENGTH
      ? value
      : `${value.slice(0, MAX_CACHED_STRING_LENGTH - 1)}\u2026`;
  }
  if (Array.isArray(value)) {
    return value.slice(0, MAX_CACHED_ARRAY_ITEMS).map((item) => compactValue(item));
  }
  if (value && typeof value === 'object') {
    return compactRecord(value);
  }
  return value;
}

function compactScalar<T extends JsonPrimitive>(
  value: CacheJsonValue | undefined,
  fallback: T,
): JsonPrimitive {
  if (typeof value === 'string') return compactValue(value) as string;
  if (typeof value === 'number' || typeof value === 'boolean' || value === null) return value;
  return fallback;
}

function serializedBytes(value: Record<string, CacheJsonValue>): number {
  return new TextEncoder().encode(JSON.stringify(value)).byteLength;
}
