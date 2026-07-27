import { describe, expect, it } from 'vitest';
import {
  isScreenStoppingDetail,
  screenOfflineCopy,
  screenOverlayCopy,
  screenQualityNotice,
  screenStoppingCopy,
  screenStoppingTitle,
} from './ScreenRemotePanel';

describe('ScreenRemotePanel quality feedback', () => {
  it('keeps screen quality feedback short and user-facing', () => {
    const notices = [
      screenQualityNotice({ quality: 'readable', state: 'saved' }),
      screenQualityNotice({ quality: 'fast', state: 'offline' }),
      screenQualityNotice({ quality: 'readable', state: 'switching' }),
      screenQualityNotice({ quality: 'fast', state: 'failed' }),
    ];

    expect(notices).toEqual([
      'Readable will apply when screen sharing starts.',
      'Fast will apply after your Mac reconnects.',
      'Switching to Readable.',
      'Could not switch to Fast. Retrying connection.',
    ]);
    for (const notice of notices) {
      expect(notice.length).toBeLessThanOrEqual(56);
      expect(notice).not.toMatch(/relay|fallback|WebRTC|adapter|snapshot/i);
    }
  });
});

describe('ScreenRemotePanel primary copy', () => {
  it('keeps offline screen copy short and free of internal cache wording', () => {
    const copies = [screenOfflineCopy(), screenOverlayCopy('offline')];

    expect(copies).toEqual([
      'Reconnect your Mac to use screen control.',
      'Reconnect your Mac to use screen control.',
    ]);
    for (const copy of copies) {
      expect(copy.length).toBeLessThanOrEqual(56);
      expect(copy).not.toMatch(/cache|cached|relay|fallback|WebRTC|adapter|snapshot/i);
    }
  });

  it('keeps stopping screen copy user-facing', () => {
    const copies = [screenStoppingTitle(), screenStoppingCopy()];

    expect(isScreenStoppingDetail('Stopping stream')).toBe(true);
    expect(isScreenStoppingDetail(' stopping stream ')).toBe(true);
    expect(copies).toEqual(['Stopping screen sharing', 'Waiting for the Mac to finish.']);
    for (const copy of copies) {
      expect(copy.length).toBeLessThanOrEqual(56);
      expect(copy).not.toMatch(/stream|relay|fallback|WebRTC|adapter|snapshot/i);
    }
  });
});
