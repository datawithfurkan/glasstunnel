import { describe, expect, it } from 'vitest';
import {
  PASSWORD_RESET_COPY as COPY,
  isInvalidResetTokenError,
  passwordResetErrorCopy,
  passwordResetRequestErrorCopy,
  validateNewPassword,
} from './passwordReset';

const failure = (status: number | undefined, code?: string) => Object.assign(new Error('server words'), { status, code });

describe('password reset copy and checks', () => {
  it('uses the exact product wording the browser tests look for', () => {
    expect(COPY.sent).toBe('If an account exists for that email, we sent a link to reset your password. It expires in 1 hour.');
    expect(COPY.disabled).toBe("Password reset isn't available yet. Sign in with Google or GitHub instead.");
    expect(COPY.rateLimited).toBe('Too many reset requests. Wait a minute and try again.');
    expect(COPY.mismatch).toBe("The passwords don't match.");
    expect(COPY.tooShort).toBe('Use at least 8 characters.');
    expect(COPY.updated).toBe('Password updated. Sign in with your new password.');
    expect(COPY.invalidToken).toBe('This reset link has expired or was already used. Request a new one.');
    expect(COPY.sendingButton).toBe('Sending…');
    expect(COPY.updatingButton).toBe('Updating…');
  });

  it('checks length before the confirmation, without trimming passwords', () => {
    expect(validateNewPassword('short', 'short')).toBe(COPY.tooShort);
    expect(validateNewPassword('short', 'other')).toBe(COPY.tooShort);
    expect(validateNewPassword('long enough', 'long enougH')).toBe(COPY.mismatch);
    expect(validateNewPassword('x'.repeat(129), 'x'.repeat(129))).toBe(COPY.tooLong);
    expect(validateNewPassword('       8', '       8')).toBeNull();
    expect(validateNewPassword('long enough', 'long enough')).toBeNull();
  });

  it('turns reset-request failures into product words', () => {
    expect(passwordResetRequestErrorCopy(failure(400, 'RESET_PASSWORD_DISABLED'))).toBe(COPY.disabled);
    expect(passwordResetRequestErrorCopy(failure(429))).toBe(COPY.rateLimited);
    expect(passwordResetRequestErrorCopy(failure(400, 'VALIDATION_ERROR'))).toBe(COPY.invalidEmail);
    expect(passwordResetRequestErrorCopy(failure(undefined))).toBe(COPY.unavailable);
    expect(passwordResetRequestErrorCopy(failure(502))).toBe(COPY.unavailable);
    expect(passwordResetRequestErrorCopy(failure(403, 'INVALID_ORIGIN'))).toBe(COPY.requestFailed);
    expect(passwordResetRequestErrorCopy(null)).toBe(COPY.unavailable);
  });

  it('turns new-password failures into product words', () => {
    expect(isInvalidResetTokenError(failure(400, 'INVALID_TOKEN'))).toBe(true);
    expect(isInvalidResetTokenError(failure(400, 'PASSWORD_TOO_SHORT'))).toBe(false);
    expect(passwordResetErrorCopy(failure(400, 'INVALID_TOKEN'))).toBe(COPY.invalidToken);
    expect(passwordResetErrorCopy(failure(400, 'PASSWORD_TOO_SHORT'))).toBe(COPY.tooShort);
    expect(passwordResetErrorCopy(failure(400, 'PASSWORD_TOO_LONG'))).toBe(COPY.tooLong);
    expect(passwordResetErrorCopy(failure(429))).toBe(COPY.tooManyAttempts);
    expect(passwordResetErrorCopy(failure(503))).toBe(COPY.unavailable);
    expect(passwordResetErrorCopy(failure(400, 'SOMETHING_ELSE'))).toBe(COPY.resetFailed);
  });
});
