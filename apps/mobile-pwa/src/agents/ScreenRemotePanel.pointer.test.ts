import { describe, expect, it } from 'vitest';
import { normalizedScreenPoint } from './ScreenRemotePanel';

function elementWithRect(rect: Pick<DOMRect, 'left' | 'top' | 'width' | 'height'>): HTMLElement {
  return {
    getBoundingClientRect: () => rect as DOMRect,
  } as HTMLElement;
}

describe('normalizedScreenPoint', () => {
  it('maps the center of letterboxed screen content to the center of the Mac', () => {
    const element = elementWithRect({ left: 10, top: 20, width: 300, height: 300 });

    expect(normalizedScreenPoint(element, 160, 170, 1920, 1080)).toEqual({ x: 0.5, y: 0.5 });
  });

  it('rejects taps in letterbox padding instead of clicking the Mac', () => {
    const element = elementWithRect({ left: 10, top: 20, width: 300, height: 300 });

    expect(normalizedScreenPoint(element, 160, 30, 1920, 1080)).toBeNull();
  });

  it('maps content edges after horizontal pillarboxing', () => {
    const element = elementWithRect({ left: 0, top: 0, width: 400, height: 200 });

    expect(normalizedScreenPoint(element, 125, 0, 300, 400)).toEqual({ x: 0, y: 0 });
    expect(normalizedScreenPoint(element, 275, 200, 300, 400)).toEqual({ x: 1, y: 1 });
  });
});
