import { describe, expect, it } from 'vitest';
import { PeerFlowAbortRegistry } from './PeerFlowAbortRegistry';

describe('PeerFlowAbortRegistry', () => {
  it('aborts a superseded flow of the same kind', () => {
    const registry = new PeerFlowAbortRegistry();

    const first = registry.begin('video');
    const second = registry.begin('video');

    expect(first.aborted).toBe(true);
    expect(second.aborted).toBe(false);
  });

  it('aborts primary and video flows during shared transport cleanup', () => {
    const registry = new PeerFlowAbortRegistry();
    const primary = registry.begin('primary');
    const video = registry.begin('video');

    registry.cancelAll();

    expect(primary.aborted).toBe(true);
    expect(video.aborted).toBe(true);
  });
});
