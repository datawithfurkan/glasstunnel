import { describe, expect, it } from 'vitest';
import { SIGN_IN_COPY, authScreenShellClassName } from './AuthScreen';

describe('AuthScreen mobile layout', () => {
  it('keeps sign-in actions reachable on short mobile browser viewports', () => {
    expect(authScreenShellClassName()).toContain('overflow-y-auto');
    expect(authScreenShellClassName()).toContain('safe-pad-top');
    expect(authScreenShellClassName()).toContain('safe-pad-bottom');
  });
});

describe('AuthScreen first-visit guidance', () => {
  it('names the Mac account and links to the Mac app install', () => {
    expect(SIGN_IN_COPY.detail).toContain('same account');
    expect(SIGN_IN_COPY.detail).toContain('Mac');
    expect(SIGN_IN_COPY.installUrl).toBe('https://glasstunnel.io/#install');
  });
});
