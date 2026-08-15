export const LIFECYCLE_RECOVERY_DEBOUNCE_MS = 200;
export const PAGE_RESUME_FORCE_RESTART_THRESHOLD_MS = 1_500;

export interface LifecycleRecoveryRequest {
  forceRestart: boolean;
  reason: string;
}

export function pageResumeRecoveryRequest(hiddenDurationMs: number): LifecycleRecoveryRequest {
  return {
    forceRestart: hiddenDurationMs > PAGE_RESUME_FORCE_RESTART_THRESHOLD_MS,
    reason: 'page-resume',
  };
}

export function pageShowRecoveryRequest(persisted: boolean): LifecycleRecoveryRequest {
  return {
    forceRestart: persisted,
    reason: 'page-show',
  };
}

export function focusRecoveryRequest(): LifecycleRecoveryRequest {
  return {
    forceRestart: false,
    reason: 'focus',
  };
}

export function networkOnlineRecoveryRequest(): LifecycleRecoveryRequest {
  return {
    forceRestart: false,
    reason: 'network-online',
  };
}

export function mergeLifecycleRecoveryRequest(
  pending: LifecycleRecoveryRequest | null,
  next: LifecycleRecoveryRequest,
): LifecycleRecoveryRequest {
  return {
    forceRestart: (pending?.forceRestart ?? false) || next.forceRestart,
    reason: next.reason,
  };
}
