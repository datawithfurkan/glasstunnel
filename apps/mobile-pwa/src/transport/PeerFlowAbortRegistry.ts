export type PeerFlowKind = 'primary' | 'video';

export class PeerFlowAbortRegistry {
  private readonly controllers = new Map<PeerFlowKind, AbortController>();

  begin(kind: PeerFlowKind): AbortSignal {
    this.cancel(kind);
    const controller = new AbortController();
    this.controllers.set(kind, controller);
    return controller.signal;
  }

  cancel(kind: PeerFlowKind): void {
    this.controllers.get(kind)?.abort();
    this.controllers.delete(kind);
  }

  cancelAll(): void {
    for (const controller of this.controllers.values()) {
      controller.abort();
    }
    this.controllers.clear();
  }
}
