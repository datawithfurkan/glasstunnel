import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  AccountApiError,
  fetchAccountHosts,
  isAccountApiAuthFailure,
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

  it('classifies rejected Supabase bearer tokens as auth failures', async () => {
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
