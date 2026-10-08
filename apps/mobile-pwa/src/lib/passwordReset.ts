// Password reset by email: the visible copy, the screen states the store keeps,
// and how auth errors become words. Kept free of the auth client so the store,
// the screens, and their tests share one source of truth.

/** Better Auth's default minimum and maximum password lengths. */
export const PASSWORD_MIN_LENGTH = 8;
export const PASSWORD_MAX_LENGTH = 128;

export const PASSWORD_RESET_COPY = {
  forgotButton: 'Forgot password?',
  forgotHeading: 'Reset your password',
  forgotDetail: "Enter the email you sign in with. We'll send you a link to choose a new password.",
  sendButton: 'Send reset link',
  sendingButton: 'Sending…',
  sent: 'If an account exists for that email, we sent a link to reset your password. It expires in 1 hour.',
  disabled: "Password reset isn't available yet. Sign in with Google or GitHub instead.",
  rateLimited: 'Too many reset requests. Wait a minute and try again.',
  emptyEmail: 'Enter an email address.',
  invalidEmail: 'Enter a valid email address.',
  requestFailed: 'Could not send the reset link. Try again.',
  backToSignIn: 'Back to sign in',
  resetHeading: 'Choose a new password',
  resetDetail: 'Updating your password signs you out on every device.',
  newPasswordLabel: 'New password',
  confirmPasswordLabel: 'Confirm new password',
  updateButton: 'Update password',
  updatingButton: 'Updating…',
  cancel: 'Cancel',
  mismatch: "The passwords don't match.",
  tooShort: `Use at least ${PASSWORD_MIN_LENGTH} characters.`,
  tooLong: `Use ${PASSWORD_MAX_LENGTH} characters or fewer.`,
  tooManyAttempts: 'Too many attempts. Wait a minute and try again.',
  updated: 'Password updated. Sign in with your new password.',
  invalidToken: 'This reset link has expired or was already used. Request a new one.',
  requestNewLink: 'Request a new link',
  resetFailed: 'Could not update your password. Try again.',
  unavailable: 'Could not reach the sign-in service. Check your connection and try again.',
  notConfigured: 'Hosted account login is not configured.',
} as const;

/** The forgot screen: ask for a reset email. */
export interface ForgotPasswordFlow {
  screen: 'forgot';
  status: 'idle' | 'sending' | 'sent';
  error: string | null;
}

/** The reset screen: choose a new password with the token from the email link. */
export interface ResetPasswordFlow {
  screen: 'reset';
  /** Null once the token was used or found invalid. */
  token: string | null;
  status: 'idle' | 'updating' | 'done' | 'invalid';
  error: string | null;
}

export type PasswordResetFlow = ForgotPasswordFlow | ResetPasswordFlow;

/** Checks a new password before it is sent: length first, then the confirmation. */
export function validateNewPassword(newPassword: string, confirmPassword: string): string | null {
  if (newPassword.length < PASSWORD_MIN_LENGTH) return PASSWORD_RESET_COPY.tooShort;
  if (newPassword.length > PASSWORD_MAX_LENGTH) return PASSWORD_RESET_COPY.tooLong;
  if (newPassword !== confirmPassword) return PASSWORD_RESET_COPY.mismatch;
  return null;
}

function errorDetails(error: unknown): { code: string; status: number | undefined } {
  const candidate = (error ?? {}) as { code?: unknown; status?: unknown };
  return {
    code: typeof candidate.code === 'string' ? candidate.code : '',
    status: typeof candidate.status === 'number' ? candidate.status : undefined,
  };
}

function isUnavailable(status: number | undefined) {
  return status === undefined || status === 0 || status >= 500;
}

export function isInvalidResetTokenError(error: unknown): boolean {
  return errorDetails(error).code === 'INVALID_TOKEN';
}

/** Words for a failed "send reset link" request. */
export function passwordResetRequestErrorCopy(error: unknown): string {
  const { code, status } = errorDetails(error);
  if (code === 'RESET_PASSWORD_DISABLED') return PASSWORD_RESET_COPY.disabled;
  if (status === 429) return PASSWORD_RESET_COPY.rateLimited;
  if (code === 'VALIDATION_ERROR' || code === 'INVALID_EMAIL') return PASSWORD_RESET_COPY.invalidEmail;
  if (isUnavailable(status)) return PASSWORD_RESET_COPY.unavailable;
  return PASSWORD_RESET_COPY.requestFailed;
}

/** Words for a failed "update password" request other than an invalid token. */
export function passwordResetErrorCopy(error: unknown): string {
  const { code, status } = errorDetails(error);
  if (code === 'INVALID_TOKEN') return PASSWORD_RESET_COPY.invalidToken;
  if (code === 'PASSWORD_TOO_SHORT') return PASSWORD_RESET_COPY.tooShort;
  if (code === 'PASSWORD_TOO_LONG') return PASSWORD_RESET_COPY.tooLong;
  if (status === 429) return PASSWORD_RESET_COPY.tooManyAttempts;
  if (isUnavailable(status)) return PASSWORD_RESET_COPY.unavailable;
  return PASSWORD_RESET_COPY.resetFailed;
}
