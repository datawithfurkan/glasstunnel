import { describe, expect, it } from 'vitest';
import {
  SCREEN_STREAM_CONNECTING_MESSAGE,
  SCREEN_STREAM_DISCONNECTED_MESSAGE,
  isScreenStreamStatusMessage,
} from './screenStreamStatus';

describe('screen stream status messages', () => {
  it('classifies screen-only status messages separately from workspace connection errors', () => {
    expect(isScreenStreamStatusMessage(SCREEN_STREAM_CONNECTING_MESSAGE)).toBe(true);
    expect(isScreenStreamStatusMessage(SCREEN_STREAM_DISCONNECTED_MESSAGE)).toBe(true);
    expect(isScreenStreamStatusMessage('Screen disconnected while reconnecting.')).toBe(true);
    expect(isScreenStreamStatusMessage('Relay connection dropped. Reconnecting automatically...')).toBe(false);
    expect(isScreenStreamStatusMessage(null)).toBe(false);
  });
});
