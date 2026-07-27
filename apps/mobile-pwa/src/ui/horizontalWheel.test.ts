import { describe, expect, it } from 'vitest';
import {
  canConsumeHorizontalWheel,
  dominantWheelDelta,
  nextHorizontalScrollLeft,
} from './horizontalWheel';

describe('horizontal wheel helpers', () => {
  it('uses the dominant wheel axis', () => {
    expect(dominantWheelDelta({ deltaX: 12, deltaY: 80 })).toBe(80);
    expect(dominantWheelDelta({ deltaX: -48, deltaY: 10 })).toBe(-48);
  });

  it('consumes wheel input while horizontal content can still move', () => {
    expect(
      canConsumeHorizontalWheel({
        clientWidth: 320,
        delta: 96,
        scrollLeft: 0,
        scrollWidth: 900,
      }),
    ).toBe(true);

    expect(
      nextHorizontalScrollLeft({
        clientWidth: 320,
        delta: 96,
        scrollLeft: 0,
        scrollWidth: 900,
      }),
    ).toBe(96);
  });

  it('lets the page keep scrolling at horizontal edges', () => {
    expect(
      canConsumeHorizontalWheel({
        clientWidth: 320,
        delta: -20,
        scrollLeft: 0,
        scrollWidth: 900,
      }),
    ).toBe(false);

    expect(
      canConsumeHorizontalWheel({
        clientWidth: 320,
        delta: 20,
        scrollLeft: 580,
        scrollWidth: 900,
      }),
    ).toBe(false);
  });

  it('ignores wheel input when the strip does not overflow', () => {
    expect(
      canConsumeHorizontalWheel({
        clientWidth: 900,
        delta: 40,
        scrollLeft: 0,
        scrollWidth: 900,
      }),
    ).toBe(false);
  });
});
