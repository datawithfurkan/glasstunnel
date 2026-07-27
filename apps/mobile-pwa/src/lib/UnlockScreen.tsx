import { useState } from 'react';
import { useAppStore } from './store';
import { BrandMark } from '../ui/Brand';

/**
 * Biometric unlock gate. Uses WebAuthn when supported; falls back to a
 * confirm-tap when the browser doesn't expose a platform authenticator.
 *
 * On successful unlock we start the WebRTC peer with the selected Mac.
 */
export function UnlockScreen() {
  const paired = useAppStore((s) => s.pairedHost);
  const user = useAppStore((s) => s.user);
  const startPeer = useAppStore((s) => s.startPeer);
  const setLocked = useAppStore((s) => s.setLocked);
  const navigateTo = useAppStore((s) => s.navigateTo);
  const forgetCurrentMac = useAppStore((s) => s.forgetCurrentMac);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const biometricAvailable = canAttemptBiometricUnlock();

  const unlock = async () => {
    setErr(null);
    setBusy(true);
    try {
      await performBiometricUnlock(paired?.deviceId ?? 'glasstunnel');
      setLocked(false);
      navigateTo('workspace');
      await startPeer();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="h-full flex flex-col items-center justify-center safe-pad-x gap-6">
      <div className="gt-panel w-full max-w-sm p-6 text-center">
        <div className="mx-auto flex h-16 w-16 items-center justify-center rounded-[8px] border border-[color:var(--gt-border-strong)] bg-surface-0 p-2">
          <BrandMark className="h-11 w-11 object-contain select-none" />
        </div>
        <div className="gt-kicker mt-4">Glasstunnel</div>
        <div className="mt-3 text-2xl font-semibold">Unlock</div>
        <div className="gt-muted mt-2 text-sm">
          {paired ? (
            <>
              Connected to <span className="text-[color:var(--gt-text)]">{paired.label}</span>
            </>
          ) : (
            'Choose a Mac first'
          )}
        </div>

        {paired ? (
          <>
            <div className="mt-5 space-y-2 text-left text-sm">
              <div className="flex items-center gap-2">
                <span className="gt-status-dot bg-accent" />
                <span className="gt-muted">
                  {biometricAvailable ? 'Secure unlock is available on this device.' : 'Device unlock is active on this device.'}
                </span>
              </div>
            </div>

            <button
              onClick={unlock}
              disabled={busy}
              className="gt-button gt-button-primary mt-6 w-full justify-center py-3"
            >
              {busy ? 'Unlocking...' : biometricAvailable ? 'Unlock with Face ID' : 'Unlock'}
            </button>
            {err && <div className="mt-3 text-center text-sm text-err">{err}</div>}
            <button
              onClick={() => void forgetCurrentMac()}
              className="mt-4 text-sm underline gt-dim"
            >
              Choose another Mac
            </button>
          </>
        ) : (
          <button
            onClick={() => navigateTo(user ? 'hosts' : 'auth')}
            className="gt-button gt-button-primary mt-6 w-full justify-center py-3"
          >
            {user ? 'Choose a Mac' : 'Sign in'}
          </button>
        )}
      </div>
    </div>
  );
}

function enrollmentKey(hostDeviceId: string): string {
  return `gt.webauthn.enrolled.${hostDeviceId}`;
}

async function performBiometricUnlock(hostDeviceId: string): Promise<void> {
  if (!canAttemptBiometricUnlock()) {
    return;
  }
  try {
    const available = await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();
    if (!available) return;
  } catch {
    return;
  }

  const key = enrollmentKey(hostDeviceId);
  if (!localStorage.getItem(key)) {
    const challenge = new Uint8Array(32);
    crypto.getRandomValues(challenge);
    const userId = new TextEncoder().encode(`glasstunnel:${hostDeviceId}`).slice(0, 64);

    const credential = await navigator.credentials.create({
      publicKey: {
        challenge,
        rp: {
          id: window.location.hostname || undefined,
          name: 'Glasstunnel',
        },
        user: {
          id: userId,
          name: `glasstunnel-${hostDeviceId}`,
          displayName: 'Glasstunnel',
        },
        pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
        authenticatorSelection: {
          authenticatorAttachment: 'platform',
          residentKey: 'required',
          userVerification: 'required',
        },
        timeout: 30_000,
        attestation: 'none',
      },
    });
    if (!credential) {
      throw new Error('Biometric setup did not complete.');
    }

    localStorage.setItem(key, '1');
    return;
  }

  const challenge = new Uint8Array(32);
  crypto.getRandomValues(challenge);
  const assertion = await navigator.credentials.get({
    publicKey: {
      challenge,
      userVerification: 'required',
      rpId: window.location.hostname || undefined,
      timeout: 30_000,
    },
  });
  if (!assertion) {
    throw new Error('Biometric unlock did not complete.');
  }
}

function canAttemptBiometricUnlock(): boolean {
  if (typeof window === 'undefined' || typeof navigator === 'undefined') {
    return false;
  }
  if (!window.isSecureContext) {
    return false;
  }
  if (!('credentials' in navigator) || typeof PublicKeyCredential === 'undefined') {
    return false;
  }
  return true;
}
