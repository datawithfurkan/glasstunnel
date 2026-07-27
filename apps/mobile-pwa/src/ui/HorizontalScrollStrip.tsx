import { useCallback, useEffect, useState, type ReactNode } from 'react';
import { useHorizontalWheelScroll } from './horizontalWheel';

interface HorizontalScrollStripProps {
  ariaLabel: string;
  children: ReactNode;
  className?: string;
  contentClassName?: string;
}

interface ScrollAffordance {
  back: boolean;
  forward: boolean;
}

const EDGE_TOLERANCE_PX = 1;

export function HorizontalScrollStrip({
  ariaLabel,
  children,
  className = '',
  contentClassName = 'flex gap-2 overflow-x-auto scrollbar-none',
}: HorizontalScrollStripProps) {
  const horizontalScroll = useHorizontalWheelScroll<HTMLDivElement>();
  const [affordance, setAffordance] = useState<ScrollAffordance>({ back: false, forward: false });

  const updateAffordance = useCallback(() => {
    const element = horizontalScroll.ref.current;
    if (!element) return;

    const maxScrollLeft = Math.max(0, element.scrollWidth - element.clientWidth);
    setAffordance({
      back: element.scrollLeft > EDGE_TOLERANCE_PX,
      forward: element.scrollLeft < maxScrollLeft - EDGE_TOLERANCE_PX,
    });
  }, [horizontalScroll.ref]);

  useEffect(() => {
    const element = horizontalScroll.ref.current;
    if (!element) return;

    const frame = window.requestAnimationFrame(updateAffordance);
    element.addEventListener('scroll', updateAffordance, { passive: true });
    window.addEventListener('resize', updateAffordance);

    return () => {
      window.cancelAnimationFrame(frame);
      element.removeEventListener('scroll', updateAffordance);
      window.removeEventListener('resize', updateAffordance);
    };
  }, [children, horizontalScroll.ref, updateAffordance]);

  const move = useCallback(
    (direction: -1 | 1) => {
      const element = horizontalScroll.ref.current;
      if (!element) return;

      const amount = Math.max(180, Math.round(element.clientWidth * 0.7));
      element.scrollBy({ left: amount * direction, behavior: 'smooth' });
      window.requestAnimationFrame(updateAffordance);
    },
    [horizontalScroll.ref, updateAffordance],
  );

  return (
    <div className={`horizontal-strip group relative ${className}`}>
      <div
        ref={horizontalScroll.ref}
        onWheel={horizontalScroll.onWheel}
        className={contentClassName}
        aria-label={ariaLabel}
      >
        {children}
      </div>
      {affordance.back && (
        <button
          type="button"
          className="horizontal-strip-button horizontal-strip-button-left"
          onClick={() => move(-1)}
          aria-label={`Scroll ${ariaLabel} left`}
          title={`Scroll ${ariaLabel} left`}
        >
          <ChevronLeftIcon />
        </button>
      )}
      {affordance.forward && (
        <button
          type="button"
          className="horizontal-strip-button horizontal-strip-button-right"
          onClick={() => move(1)}
          aria-label={`Scroll ${ariaLabel} right`}
          title={`Scroll ${ariaLabel} right`}
        >
          <ChevronRightIcon />
        </button>
      )}
    </div>
  );
}

function ChevronLeftIcon() {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true" className="h-4 w-4">
      <path
        d="M12.5 4.5 7 10l5.5 5.5"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function ChevronRightIcon() {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true" className="h-4 w-4">
      <path
        d="m7.5 4.5 5.5 5.5-5.5 5.5"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
