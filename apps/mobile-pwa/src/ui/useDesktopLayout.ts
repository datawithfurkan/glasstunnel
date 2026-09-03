import { useSyncExternalStore } from 'react';

/** Matches Tailwind's `md` breakpoint, which the workspace uses to switch layouts. */
export const DESKTOP_LAYOUT_MIN_WIDTH_PX = 768;
export const DESKTOP_LAYOUT_MEDIA_QUERY = `(min-width: ${DESKTOP_LAYOUT_MIN_WIDTH_PX}px)`;

export function isDesktopLayoutWidth(viewportWidthPx: number): boolean {
  return viewportWidthPx >= DESKTOP_LAYOUT_MIN_WIDTH_PX;
}

function mediaQueryList(): MediaQueryList | null {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return null;
  return window.matchMedia(DESKTOP_LAYOUT_MEDIA_QUERY);
}

function subscribe(onChange: () => void): () => void {
  const query = mediaQueryList();
  if (!query) return () => {};
  query.addEventListener('change', onChange);
  return () => query.removeEventListener('change', onChange);
}

function getSnapshot(): boolean {
  const query = mediaQueryList();
  if (query) return query.matches;
  if (typeof window !== 'undefined' && typeof window.innerWidth === 'number') {
    return isDesktopLayoutWidth(window.innerWidth);
  }
  return false;
}

function getServerSnapshot(): boolean {
  return false;
}

/**
 * True when the viewport is wide enough for the desktop workspace layout.
 *
 * The workspace used to render both the phone and the desktop trees and hide one
 * with CSS, which mounted every panel twice (two screen video sinks, two start
 * requests, two restart timers). Choosing the layout here mounts exactly one.
 */
export function useDesktopLayout(): boolean {
  return useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
}
