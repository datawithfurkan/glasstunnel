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
