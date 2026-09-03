import { describe, expect, it } from 'vitest';
import {
  DESKTOP_LAYOUT_MEDIA_QUERY,
  DESKTOP_LAYOUT_MIN_WIDTH_PX,
  isDesktopLayoutWidth,
} from './useDesktopLayout';

describe('desktop layout breakpoint', () => {
  it('matches the Tailwind md breakpoint the workspace styles use', () => {
    expect(DESKTOP_LAYOUT_MIN_WIDTH_PX).toBe(768);
    expect(DESKTOP_LAYOUT_MEDIA_QUERY).toBe('(min-width: 768px)');
  });

  it('treats phone widths as the single-column layout and tablets as desktop', () => {
    expect(isDesktopLayoutWidth(375)).toBe(false);
    expect(isDesktopLayoutWidth(767)).toBe(false);
    expect(isDesktopLayoutWidth(768)).toBe(true);
    expect(isDesktopLayoutWidth(1280)).toBe(true);
  });
});
