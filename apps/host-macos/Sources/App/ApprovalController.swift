import Foundation
import GTProtocol
import GTSecurity

/// Manages the queue of pending device approvals.
///
/// When a new phone requests access, the host can approve or reject it.
/// Approved devices are added to the `DeviceRegistry`.
///
/// This is a plain (non-ObservableObject) controller. AppState owns the
/// @Published `activeApproval` property and drives the UI.
@MainActor
final class ApprovalController {
    struct PendingDeviceApproval: Identifiable, Equatable {
        let id: String
        let requesterDeviceID: DeviceID
        let requesterPublicKeyB64: String
        let requesterLabel: String
        let requestedAt: Date?
    }

    private let registry: DeviceRegistry
    private var approvalQueue: [PendingDeviceApproval] = []
    private var onDecision: ((String, Bool) async -> Void)?
    private var onRegistryAdd: ((DeviceRegistry.PairedDevice) throws -> Void)?
    private var onActiveChanged: ((PendingDeviceApproval?) -> Void)?

    /// The currently-visible approval. AppState mirrors this via @Published.
    private(set) var activeApproval: PendingDeviceApproval? = nil {
        didSet { onActiveChanged?(activeApproval) }
    }

    var pendingApprovalCount: Int {
        (activeApproval == nil ? 0 : 1) + approvalQueue.count
    }

    var visiblePendingApprovals: [PendingDeviceApproval] {
        (activeApproval.map { [$0] } ?? []) + approvalQueue
    }

    init(registry: DeviceRegistry = .shared) {
        self.registry = registry
    }

    func setActiveChangedHandler(_ handler: @escaping (PendingDeviceApproval?) -> Void) {
        self.onActiveChanged = handler
    }

    func setDecisionHandler(_ handler: @escaping (String, Bool) async -> Void) {
        self.onDecision = handler
    }

    func setRegistryAddHandler(_ handler: @escaping (DeviceRegistry.PairedDevice) throws -> Void) {
        self.onRegistryAdd = handler
    }

    /// Called by the session manager when a new approval request arrives.
    func enqueue(
        id: String,
        requesterDeviceID: DeviceID,
        requesterPublicKeyB64: String,
        requesterLabel: String,
        requestedAt: Date?
    ) {
        let pending = PendingDeviceApproval(
            id: id,
            requesterDeviceID: requesterDeviceID,
            requesterPublicKeyB64: requesterPublicKeyB64,
            requesterLabel: requesterLabel,
            requestedAt: requestedAt
        )

        // Auto-approve already-known devices.
        if registry.isKnown(pending.requesterDeviceID) {
            let controller = self
            Task { @MainActor [controller, pending] in
                await controller.onDecision?(pending.id, true)
            }
            return
        }

        // Deduplicate.
        if activeApproval?.id == pending.id || approvalQueue.contains(where: { $0.id == pending.id }) {
            return
        }

        if activeApproval == nil {
            activeApproval = pending
        } else {
            approvalQueue.append(pending)
        }
    }

    func approveActive() {
        guard let request = activeApproval else { return }
        Task { @MainActor in
            await handleDecision(request, approved: true)
        }
    }

    func rejectActive() {
        guard let request = activeApproval else { return }
        Task { @MainActor in
            await handleDecision(request, approved: false)
        }
    }

    func clearActive() {
        activeApproval = nil
        approvalQueue.removeAll()
    }

    private func handleDecision(_ request: PendingDeviceApproval, approved: Bool) async {
        defer { advanceQueue(after: request.id) }

        var shouldApprove = approved
        if approved {
            if let publicKey = Data(base64Encoded: request.requesterPublicKeyB64) {
                do {
                    try onRegistryAdd?(
                        DeviceRegistry.PairedDevice(
                            deviceId: request.requesterDeviceID,
                            publicKey: publicKey,
                            label: request.requesterLabel
                        )
                    )
                } catch {
                    shouldApprove = false
                }
            } else {
                shouldApprove = false
            }
        }

        await onDecision?(request.id, shouldApprove)
    }

    private func advanceQueue(after requestID: String) {
        if activeApproval?.id == requestID {
            activeApproval = approvalQueue.isEmpty ? nil : approvalQueue.removeFirst()
        } else {
            approvalQueue.removeAll { $0.id == requestID }
        }
    }
}
