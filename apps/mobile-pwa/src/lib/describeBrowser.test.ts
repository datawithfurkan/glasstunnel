import { describe, expect, it, vi } from 'vitest';

vi.mock('idb-keyval', () => ({ get: vi.fn(), set: vi.fn(), del: vi.fn(), keys: vi.fn(async () => []) }));
import { describeBrowser } from './store';

const UA = {
  chromeMac: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36',
  safariMac: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15',
  edgeWindows: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0',
  firefoxLinux: 'Mozilla/5.0 (X11; Linux x86_64; rv:143.0) Gecko/20100101 Firefox/143.0',
  chromeIphone: 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_6_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/155.0.8059.37 Mobile/15E148 Safari/604.1',
  safariIphone: 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1',
  chromeAndroid: 'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36',
};

describe('browser names in the Mac device list', () => {
  it.each([
    [UA.chromeMac, 0, 'Chrome on Mac'],
    [UA.safariMac, 0, 'Safari on Mac'],
    // iPadOS asks for the desktop site and reports a Mac with touch.
    [UA.safariMac, 5, 'Safari on iPad'],
    [UA.edgeWindows, 0, 'Edge on Windows'],
    [UA.firefoxLinux, 0, 'Firefox on Linux'],
    [UA.chromeIphone, 5, 'Chrome on iPhone'],
    [UA.safariIphone, 5, 'Safari on iPhone'],
    [UA.chromeAndroid, 5, 'Chrome on Android'],
  ])('names %s', (userAgent, touchPoints, expected) => {
    expect(describeBrowser(userAgent, touchPoints)).toBe(expected);
  });

  it('falls back to a plain name it can always show', () => {
    expect(describeBrowser('SomethingElse/1.0')).toBe('Browser');
  });
});
