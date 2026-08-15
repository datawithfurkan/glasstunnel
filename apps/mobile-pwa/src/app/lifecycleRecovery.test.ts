import { describe, expect, it } from 'vitest';
import {
  focusRecoveryRequest,
  mergeLifecycleRecoveryRequest,
  networkOnlineRecoveryRequest,
  pageResumeRecoveryRequest,
  pageShowRecoveryRequest,
} from './lifecycleRecovery';

describe('lifecycle recovery requests', () => {
  it('does not force restart on network online events', () => {
    expect(networkOnlineRecoveryRequest()).toEqual({
      forceRestart: false,
      reason: 'network-online',
    });
  });

  it('only force-restarts page resume after the suspension threshold', () => {
    expect(pageResumeRecoveryRequest(1_500)).toEqual({
      forceRestart: false,
      reason: 'page-resume',
    });
    expect(pageResumeRecoveryRequest(1_501)).toEqual({
      forceRestart: true,
      reason: 'page-resume',
    });
  });

  it('preserves the strongest restart intent when lifecycle events are debounced together', () => {
    const merged = [pageShowRecoveryRequest(true), focusRecoveryRequest(), networkOnlineRecoveryRequest()]
      .reduce(mergeLifecycleRecoveryRequest, null);

    expect(merged).toEqual({
      forceRestart: true,
      reason: 'network-online',
    });
  });
});
