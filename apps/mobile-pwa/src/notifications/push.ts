/**
 * Register a Web Push subscription so the signaling server can fan out
 * agent-state notifications to this phone.
 *
 * Graceful degrade: if the browser doesn't support Web Push (or the user
 * declines), we silently no-op. The PWA still works for real-time
 * monitoring; the only loss is out-of-app "your agent is done" alerts.
 *
 * iOS Safari requires the PWA to be installed ("Add to Home Screen") before
 * push permission can be granted. We don't prompt here until we're clearly
 * running from a home-screen launch.
 */
export interface RegisterPushParams {
  phoneDeviceId: string;
  signalingHttpUrl: string;
}

export async function registerPushSubscription(params: RegisterPushParams): Promise<void> {
  try {
    if (!('serviceWorker' in navigator) || !('PushManager' in window)) return;
    if (isStandalone() === false && isIOS()) return;

    const reg = await navigator.serviceWorker.ready;
    const existing = await reg.pushManager.getSubscription();
    const vapid = await fetchVAPIDPublicKey(params.signalingHttpUrl);
    if (!vapid) return;

    let subscription: PushSubscription;
    if (existing) {
      subscription = existing;
    } else {
      const permission = await Notification.requestPermission();
      if (permission !== 'granted') return;
      const keyBytes = urlBase64ToUint8Array(vapid);
      subscription = await reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: keyBytes.buffer.slice(
          keyBytes.byteOffset,
          keyBytes.byteOffset + keyBytes.byteLength,
        ) as ArrayBuffer,
      });
    }

    const { endpoint, keys } = subscription.toJSON();
    const p256dh = (keys as Record<string, string> | undefined)?.p256dh ?? '';
    const auth = (keys as Record<string, string> | undefined)?.auth ?? '';
    if (!endpoint || !p256dh || !auth) return;

    await fetch(`${params.signalingHttpUrl}/push/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        device_id: params.phoneDeviceId,
        endpoint,
        p256dh,
        auth,
      }),
    });
  } catch {
    // swallow; push is best-effort
  }
}

async function fetchVAPIDPublicKey(base: string): Promise<string | null> {
  try {
    const resp = await fetch(`${base}/push/vapid`);
    if (!resp.ok) return null;
    const body = (await resp.json()) as { public_key?: string };
    return body.public_key ?? null;
  } catch {
    return null;
  }
}

function urlBase64ToUint8Array(base64String: string): Uint8Array {
  const padding = '='.repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
  const raw = atob(base64);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

function isStandalone(): boolean {
  const mql = window.matchMedia('(display-mode: standalone)');
  if (mql.matches) return true;
  // iOS Safari-specific flag
  if ('standalone' in navigator && (navigator as { standalone?: boolean }).standalone) return true;
  return false;
}

function isIOS(): boolean {
  return /iPhone|iPad|iPod/i.test(navigator.userAgent);
}
