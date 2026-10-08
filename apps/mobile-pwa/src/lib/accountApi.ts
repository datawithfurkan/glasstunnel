import { platformConfig } from './platform';

export interface AccountHost {
  deviceId: string;
  publicKeyB64: string;
  label: string;
  signalingUrl: string;
  turnUrl?: string;
  turnUsername?: string;
  turnPassword?: string;
  online: boolean;
  trusted: boolean;
  pairedAtUnixMs: number;
  lastSeenAtUnixMs?: number;
  /** When the Mac was added to the account; older Workers omit it (use pairedAtUnixMs). */
  addedAtUnixMs?: number;
  /** The Glasstunnel Mac app version the Mac last reported, when the server knows it. */
  appVersion?: string;
}

export interface ApprovalRequestResult {
  status: 'pending' | 'approved' | 'rejected' | 'expired';
  requestId?: string;
  host?: AccountHost;
}

export class AccountApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
    this.name = 'AccountApiError';
  }
}

export function isAccountApiAuthFailure(error: unknown): boolean {
  if (error instanceof AccountApiError && error.status === 401) return true;
  const message = error instanceof Error ? error.message : String(error);
  return /\bauth\s+(401|403)\b|missing bearer token/i.test(message);
}

function apiBaseUrl(): string {
  const signaling = platformConfig.defaultSignalingUrl;
  return signaling.replace(/^ws/i, 'http').replace(/\/signal\/?$/, '');
}

async function apiFetch<T>(accessToken: string, path: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(`${apiBaseUrl()}${path}`, {
    ...init,
    headers: {
      authorization: `Bearer ${accessToken}`,
      'content-type': 'application/json',
      ...(init.headers ?? {}),
    },
  });

  const text = await response.text();
  let payload: Record<string, unknown> = {};
  if (text) {
    try {
      payload = JSON.parse(text) as Record<string, unknown>;
    } catch {
      if (!response.ok) {
        throw new Error(`Request failed with ${response.status}: ${text.slice(0, 160)}`);
      }
      throw new Error('Invalid response from the signaling service.');
    }
  }
  if (!response.ok) {
    throw new AccountApiError(
      (payload.error as string) || `Request failed with ${response.status}`,
      response.status,
    );
  }
  return payload as T;
}

export async function registerBrowserDevice(
  accessToken: string,
  input: {
    deviceId: string;
    publicKeyB64: string;
    label: string;
    kind?: 'browser' | 'phone';
    platform?: string;
  },
): Promise<AccountHost[]> {
  const result = await apiFetch<{ hosts: AccountHost[] }>(accessToken, '/account/device/register', {
    method: 'POST',
    body: JSON.stringify({
      deviceId: input.deviceId,
      publicKeyB64: input.publicKeyB64,
      label: input.label,
      kind: input.kind ?? 'browser',
      platform: input.platform ?? navigator.userAgent,
    }),
  });
  return result.hosts ?? [];
}

export async function fetchAccountHosts(
  accessToken: string,
  requesterDeviceId: string,
): Promise<AccountHost[]> {
  const query = new URLSearchParams({ device_id: requesterDeviceId });
  const result = await apiFetch<{ hosts: AccountHost[] }>(
    accessToken,
    `/account/hosts?${query.toString()}`,
    { method: 'GET', headers: { 'content-type': 'application/json' } },
  );
  return result.hosts ?? [];
}

export async function claimHostCode(
  accessToken: string,
  input: { code: string; requesterDeviceId?: string },
): Promise<AccountHost> {
  const result = await apiFetch<{ host: AccountHost }>(accessToken, '/account/claim-host-code', {
    method: 'POST',
    body: JSON.stringify({
      code: input.code,
      requesterDeviceId: input.requesterDeviceId ?? '',
    }),
  });
  return result.host;
}

/**
 * How long a rename or removal may wait for an answer before it reports a
 * failure. The Worker gives each account-service call up to 15 s, and a
 * removal makes several in a row (look the Mac up, remove it, and after a lost
 * answer look it up again). A removal that still gets no answer is checked
 * against the list of Macs (see removeHost in store.ts).
 */
export const HOST_MANAGEMENT_TIMEOUT_MS = 45_000;

async function withRequestTimeout<T>(
  timeoutMs: number,
  request: (signal: AbortSignal) => Promise<T>,
): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await request(controller.signal);
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Renames a Mac in the signed-in account. 404 for a Mac that is not this
 * account's. `requesterDeviceId` (this browser) lets the answer say whether
 * this browser may open the Mac, as the host list does.
 */
export async function renameAccountHost(
  accessToken: string,
  input: { deviceId: string; label: string; requesterDeviceId?: string },
): Promise<AccountHost | undefined> {
  const result = await withRequestTimeout(HOST_MANAGEMENT_TIMEOUT_MS, (signal) =>
    apiFetch<{ ok?: boolean; host?: AccountHost }>(accessToken, '/account/hosts/rename', {
      method: 'POST',
      body: JSON.stringify({
        deviceId: input.deviceId,
        label: input.label,
        ...(input.requesterDeviceId ? { requesterDeviceId: input.requesterDeviceId } : {}),
      }),
      signal,
    }),
  );
  return result.host;
}

/** Removes a Mac from the signed-in account. 404 for a Mac that is not this account's. */
export async function removeAccountHost(
  accessToken: string,
  input: { deviceId: string },
): Promise<void> {
  await withRequestTimeout(HOST_MANAGEMENT_TIMEOUT_MS, (signal) =>
    apiFetch<{ ok?: boolean }>(accessToken, '/account/hosts/remove', {
      method: 'POST',
      body: JSON.stringify({ deviceId: input.deviceId }),
      signal,
    }),
  );
}

export async function requestHostApproval(
  accessToken: string,
  input: {
    hostDeviceId: string;
    requesterDeviceId: string;
    requesterPublicKeyB64: string;
    requesterLabel: string;
  },
): Promise<ApprovalRequestResult> {
  const result = await apiFetch<{
    status: ApprovalRequestResult['status'];
    request_id?: string;
    host?: AccountHost;
  }>(accessToken, '/account/request-approval', {
    method: 'POST',
    body: JSON.stringify({
      hostDeviceId: input.hostDeviceId,
      requesterDeviceId: input.requesterDeviceId,
      requesterPublicKeyB64: input.requesterPublicKeyB64,
      requesterLabel: input.requesterLabel,
    }),
  });
  return {
    status: result.status,
    requestId: result.request_id,
    host: result.host,
  };
}

export async function pollApprovalStatus(
  accessToken: string,
  requestId: string,
): Promise<ApprovalRequestResult> {
  const query = new URLSearchParams({ request_id: requestId });
  const result = await apiFetch<{
    status: ApprovalRequestResult['status'];
    host?: AccountHost;
  }>(accessToken, `/account/approval-status?${query.toString()}`, {
    method: 'GET',
    headers: { 'content-type': 'application/json' },
  });
  return {
    status: result.status,
    host: result.host,
  };
}
