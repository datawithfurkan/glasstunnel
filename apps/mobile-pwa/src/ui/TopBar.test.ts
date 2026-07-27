import { describe, expect, it } from 'vitest';
import { topBarErrorDetail } from './TopBar';

describe('topBarErrorDetail', () => {
  it('keeps workspace connection errors out of the mobile header', () => {
    expect(topBarErrorDetail('Mac offline. Open Glasstunnel on the Mac, then retry.', true)).toBeNull();
  });

  it('keeps non-workspace errors visible where there is no workspace retry banner', () => {
    expect(topBarErrorDetail('Sign-in failed.', false)).toBe('Sign-in failed.');
  });
});
