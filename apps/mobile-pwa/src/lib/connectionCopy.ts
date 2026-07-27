export type ConnectionCopyState =
  | 'connecting'
  | 'reconnecting'
  | 'cached-reconnecting'
  | 'offline-cached'
  | 'offline-retry'
  | 'screen-stop-pending'
  | 'screen-stop-delayed'
  | 'screen-stop-unconfirmed'
  | 'remote-start-failed';

export function connectionStatusCopy(state: ConnectionCopyState): string {
  switch (state) {
    case 'connecting':
      return 'Connecting to your Mac.';
    case 'reconnecting':
      return 'Connection lost. Reconnecting.';
    case 'cached-reconnecting':
      return 'Reconnecting to your Mac.';
    case 'offline-cached':
      return 'Mac offline. Showing recent workspace.';
    case 'offline-retry':
      return 'Mac offline. Open Glasstunnel on the Mac, then retry.';
    case 'screen-stop-pending':
      return 'Screen sharing will stop when the Mac reconnects.';
    case 'screen-stop-delayed':
      return 'Could not reach your Mac. Screen sharing will stop when it reconnects.';
    case 'screen-stop-unconfirmed':
      return 'Screen sharing is still stopping. Keep Glasstunnel open on the Mac.';
    case 'remote-start-failed':
      return 'Could not reach your Mac to start this app.';
  }
}
