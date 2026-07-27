export const SCREEN_STREAM_CONNECTING_MESSAGE =
  'Screen stream is connecting. Keep Glasstunnel open on the Mac.';

export const SCREEN_STREAM_DISCONNECTED_MESSAGE =
  'Screen stream disconnected. Retry screen to reconnect.';

export function isScreenStreamStatusMessage(message: string | null | undefined): boolean {
  if (!message) return false;
  const lower = message.toLowerCase();
  return (
    lower.includes('screen stream is connecting') ||
    lower.includes('screen stream disconnected') ||
    lower.includes('screen disconnected')
  );
}
