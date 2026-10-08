/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_PUBLIC_APP_URL?: string;
  readonly VITE_SIGNALING_URL?: string;
  /** Convex deployment (https://<name>.convex.cloud). */
  readonly VITE_CONVEX_URL?: string;
  /** Auth server (https://<name>.convex.site); derived from VITE_CONVEX_URL when unset. */
  readonly VITE_CONVEX_SITE_URL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
