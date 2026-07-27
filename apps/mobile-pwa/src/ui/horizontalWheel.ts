import { useCallback, useRef, type WheelEvent } from 'react';

interface WheelDeltaInput {
  deltaX: number;
  deltaY: number;
}

interface HorizontalScrollInput {
  clientWidth: number;
  delta: number;
  scrollLeft: number;
  scrollWidth: number;
}

const EDGE_TOLERANCE_PX = 1;

export function dominantWheelDelta({ deltaX, deltaY }: WheelDeltaInput): number {
  return Math.abs(deltaX) > Math.abs(deltaY) ? deltaX : deltaY;
}

export function canConsumeHorizontalWheel({
  clientWidth,
  delta,
  scrollLeft,
  scrollWidth,
}: HorizontalScrollInput): boolean {
  if (delta === 0) return false;
  const maxScrollLeft = Math.max(0, scrollWidth - clientWidth);
  if (maxScrollLeft <= EDGE_TOLERANCE_PX) return false;
  if (delta < 0) return scrollLeft > EDGE_TOLERANCE_PX;
  return scrollLeft < maxScrollLeft - EDGE_TOLERANCE_PX;
}

export function nextHorizontalScrollLeft({
  clientWidth,
  delta,
  scrollLeft,
  scrollWidth,
}: HorizontalScrollInput): number {
  const maxScrollLeft = Math.max(0, scrollWidth - clientWidth);
  return Math.min(maxScrollLeft, Math.max(0, scrollLeft + delta));
}

export function useHorizontalWheelScroll<T extends HTMLElement>() {
  const ref = useRef<T | null>(null);

  const onWheel = useCallback((event: WheelEvent<T>) => {
    const element = event.currentTarget;
    const delta = dominantWheelDelta({
      deltaX: event.deltaX,
      deltaY: event.deltaY,
    });

    if (
      !canConsumeHorizontalWheel({
        clientWidth: element.clientWidth,
        delta,
        scrollLeft: element.scrollLeft,
        scrollWidth: element.scrollWidth,
      })
    ) {
      return;
    }

    event.preventDefault();
    element.scrollLeft = nextHorizontalScrollLeft({
      clientWidth: element.clientWidth,
      delta,
      scrollLeft: element.scrollLeft,
      scrollWidth: element.scrollWidth,
    });
  }, []);

  return { ref, onWheel };
}
