import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  AccountApiError,
  HOST_MANAGEMENT_TIMEOUT_MS,
  fetchAccountHosts,
  isAccountApiAuthFailure,
  removeAccountHost,
  renameAccountHost,
} from './accountApi';

describe('account API errors', () => {
  const fetchMock = vi.fn();

  beforeEach(() => {
    fetchMock.mockReset();
    vi.stubGlobal('fetch', fetchMock);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('sends the bearer token when listing account hosts', async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ hosts: [] }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    );

    const hosts = await fetchAccountHosts('access-token', 'gt-browser');

    expect(hosts).toEqual([]);
    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining('/account/hosts?device_id=gt-browser'),
      expect.objectContaining({
        headers: expect.objectContaining({
          authorization: 'Bearer access-token',
        }),
      }),
    );
  });

  it('classifies rejected session bearer tokens as auth failures', async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ ok: false, error: 'auth 403' }), {
        status: 401,
        headers: { 'content-type': 'application/json' },
      }),
    );

    let thrown: unknown;
    try {
      await fetchAccountHosts('expired-token', 'gt-browser');
    } catch (error) {
      thrown = error;
    }

    expect(thrown).toBeInstanceOf(AccountApiError);
    expect(thrown).toMatchObject({ status: 401, message: 'auth 403' });
    expect(isAccountApiAuthFailure(thrown)).toBe(true);
  });
});

describe('Mac management requests', () => {
  const fetchMock = vi.fn();
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

  beforeEach(() => {
    fetchMock.mockReset();
    vi.stubGlobal('fetch', fetchMock);
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('renames with POST /account/hosts/rename and returns the stored Mac', async () => {
    const host = {
      deviceId: 'gt-mac', publicKeyB64: 'key', label: 'Desk Mac', signalingUrl: '', online: true,
      trusted: true, pairedAtUnixMs: 1, addedAtUnixMs: 2, appVersion: '0.1.10',
    };
    fetchMock.mockImplementation(async () => json({ ok: true, host }));

    await expect(
      renameAccountHost('access-token', { deviceId: 'gt-mac', label: 'Desk Mac', requesterDeviceId: 'gt-browser' }),
    ).resolves.toEqual(host);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toMatch(/\/account\/hosts\/rename$/);
    expect(init.method).toBe('POST');
    expect(JSON.parse(String(init.body))).toEqual({ deviceId: 'gt-mac', label: 'Desk Mac', requesterDeviceId: 'gt-browser' });

    await renameAccountHost('access-token', { deviceId: 'gt-mac', label: 'Desk Mac' });
    expect(JSON.parse(String((fetchMock.mock.calls[1] as [string, RequestInit])[1].body))).toEqual({
      deviceId: 'gt-mac', label: 'Desk Mac',
    });
    expect(init.headers).toMatchObject({ authorization: 'Bearer access-token' });
    expect(init.signal).toBeInstanceOf(AbortSignal);
  });

  it('removes with POST /account/hosts/remove', async () => {
    fetchMock.mockResolvedValue(json({ ok: true }));

    await expect(removeAccountHost('access-token', { deviceId: 'gt-mac' })).resolves.toBeUndefined();
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toMatch(/\/account\/hosts\/remove$/);
    expect(init.method).toBe('POST');
    expect(JSON.parse(String(init.body))).toEqual({ deviceId: 'gt-mac' });
  });

  it('reports the status and message of a refused change', async () => {
    fetchMock.mockResolvedValue(json({ ok: false, error: 'Mac not found' }, 404));
    await expect(removeAccountHost('access-token', { deviceId: 'gt-other' })).rejects.toMatchObject({
      name: 'AccountApiError', status: 404, message: 'Mac not found',
    });

    fetchMock.mockResolvedValue(json({ ok: false, error: 'Use 40 characters or fewer.' }, 400));
    await expect(renameAccountHost('access-token', { deviceId: 'gt-mac', label: 'x' })).rejects.toMatchObject({
      status: 400, message: 'Use 40 characters or fewer.',
    });
  });

  it('gives up on an answer that never comes after 45 s, so the dialog does not stay busy', async () => {
    vi.useFakeTimers();
    let aborted = false;
    fetchMock.mockImplementation((_url: string, init: RequestInit) => new Promise((_resolve, reject) => {
      init.signal?.addEventListener('abort', () => {
        aborted = true;
        reject(Object.assign(new Error('aborted'), { name: 'AbortError' }));
      });
    }));

    // Room for several of the Worker's account-service calls, each limited to 15 s.
    expect(HOST_MANAGEMENT_TIMEOUT_MS).toBe(45_000);
    const removing = removeAccountHost('access-token', { deviceId: 'gt-mac' });
    const outcome = expect(removing).rejects.toMatchObject({ name: 'AbortError' });
    await vi.advanceTimersByTimeAsync(HOST_MANAGEMENT_TIMEOUT_MS - 1);
    expect(aborted).toBe(false);
    await vi.advanceTimersByTimeAsync(1);
    await outcome;
    expect(aborted).toBe(true);
  });
});
