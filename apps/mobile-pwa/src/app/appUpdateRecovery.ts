export const APP_UPDATE_REQUIRED_EVENT = 'glasstunnel:app-update-required';
export const APP_UPDATE_REQUIRED_COPY = {
  title: 'Refresh Glasstunnel',
  detail: 'A new version is ready. Refresh to continue.',
  action: 'Refresh',
} as const;

const VITE_PRELOAD_ERROR_EVENT = 'vite:preloadError';
const RECOVERY_STORAGE_KEY = 'glasstunnel:deployment-reload-at';
const RECOVERY_WINDOW_MS = 30_000;

interface RecoveryStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

interface AppUpdateRecoveryOptions {
  target?: EventTarget;
  storage?: RecoveryStorage | null;
  reload?: () => void;
  now?: () => number;
  scheduleStableReset?: (callback: () => void, delay: number) => number;
  cancelStableReset?: (handle: number) => void;
}

export function installAppUpdateRecovery(options: AppUpdateRecoveryOptions = {}): () => void {
  const target = options.target ?? window;
  const storage = options.storage === undefined ? sessionStorageOrNull() : options.storage;
  const reload = options.reload ?? (() => window.location.reload());
  const now = options.now ?? Date.now;
  const scheduleStableReset = options.scheduleStableReset
    ?? ((callback, delay) => window.setTimeout(callback, delay));
  const cancelStableReset = options.cancelStableReset
    ?? ((handle) => window.clearTimeout(handle));
  let reloadRequested = false;
  let resetHandle: number | undefined;

  if (readRecoveryTime(storage) !== null) {
    resetHandle = scheduleStableReset(() => {
      removeRecoveryTime(storage);
      resetHandle = undefined;
    }, RECOVERY_WINDOW_MS);
  }

  const handlePreloadError = (event: Event) => {
    event.preventDefault();
    const previousRecovery = readRecoveryTime(storage);
    const currentTime = now();
    const recentlyReloaded = previousRecovery !== null
      && currentTime >= previousRecovery
      && currentTime - previousRecovery < RECOVERY_WINDOW_MS;

    if (reloadRequested || recentlyReloaded) {
      target.dispatchEvent(new Event(APP_UPDATE_REQUIRED_EVENT));
      return;
    }

    reloadRequested = true;
    writeRecoveryTime(storage, currentTime);
    reload();
  };

  target.addEventListener(VITE_PRELOAD_ERROR_EVENT, handlePreloadError);
  return () => {
    target.removeEventListener(VITE_PRELOAD_ERROR_EVENT, handlePreloadError);
    if (resetHandle !== undefined) cancelStableReset(resetHandle);
  };
}

function sessionStorageOrNull(): RecoveryStorage | null {
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

function readRecoveryTime(storage: RecoveryStorage | null): number | null {
  if (!storage) return null;
  try {
    const value = Number(storage.getItem(RECOVERY_STORAGE_KEY));
    return Number.isFinite(value) && value > 0 ? value : null;
  } catch {
    return null;
  }
}

function writeRecoveryTime(storage: RecoveryStorage | null, value: number): void {
  try {
    storage?.setItem(RECOVERY_STORAGE_KEY, String(value));
  } catch {
    // A reload still gives the browser a chance to fetch the current app shell.
  }
}

function removeRecoveryTime(storage: RecoveryStorage | null): void {
  try {
    storage?.removeItem(RECOVERY_STORAGE_KEY);
  } catch {
    // Storage can be unavailable in restricted browser modes.
  }
}
