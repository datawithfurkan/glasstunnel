import Foundation

/// Serializes asynchronous lifecycle work while coalescing queued changes to
/// the latest desired state.
@MainActor
final class AsyncLatestStateReconciler<State> {
    typealias Reconcile = @MainActor (State) async -> Void

    private(set) var desiredValue: State
    private var desiredRevision: UInt64 = 0
    private var worker: Task<Void, Never>?
    private let reconcile: Reconcile

    init(initialValue: State, reconcile: @escaping Reconcile) {
        self.desiredValue = initialValue
        self.reconcile = reconcile
    }

    func setDesired(_ value: State) {
        desiredValue = value
        desiredRevision &+= 1
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    func waitUntilSettled() async {
        while let activeWorker = worker {
            await activeWorker.value
        }
    }

    private func run() async {
        while true {
            let target = desiredValue
            let revision = desiredRevision
            await reconcile(target)
            guard desiredRevision != revision else {
                worker = nil
                return
            }
        }
    }
}
