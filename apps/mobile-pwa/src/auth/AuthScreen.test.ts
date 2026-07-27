import { describe, expect, it } from 'vitest';
import { authScreenShellClassName } from './AuthScreen';

describe('AuthScreen mobile layout', () => {
  it('keeps sign-in actions reachable on short mobile browser viewports', () => {
    expect(authScreenShellClassName()).toContain('overflow-y-auto');
    expect(authScreenShellClassName()).toContain('safe-pad-top');
    expect(authScreenShellClassName()).toContain('safe-pad-bottom');
  });
});
