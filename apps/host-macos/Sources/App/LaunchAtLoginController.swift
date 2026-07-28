#if os(macOS)
import Combine
import Foundation
import ServiceManagement

enum LaunchAtLoginRegistrationStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

protocol LaunchAtLoginServicing {
    var status: LaunchAtLoginRegistrationStatus { get }
    func register() throws
    func unregister() throws
}

struct SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginRegistrationStatus {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    struct Feedback: Equatable {
        enum Tone: Equatable {
            case information
            case error
        }

        let message: String
        let tone: Tone
    }

    @Published private(set) var status: LaunchAtLoginRegistrationStatus
    @Published private(set) var isUpdating = false
    @Published private(set) var feedback: Feedback?

    private let service: LaunchAtLoginServicing

    init(service: LaunchAtLoginServicing = SystemLaunchAtLoginService()) {
        self.service = service
        self.status = service.status
        updateStatusFeedback()
    }

    var isEnabled: Bool {
        status == .enabled
    }

    func refresh() {
        status = service.status
        updateStatusFeedback()
    }

    func setEnabled(_ enabled: Bool) {
        guard !isUpdating else { return }
        isUpdating = true
        feedback = nil

        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            status = service.status
            updateStatusFeedback()
        } catch {
            status = service.status
            feedback = Feedback(
                message: "Could not update Launch at Login. \(error.localizedDescription)",
                tone: .error
            )
        }

        isUpdating = false
    }

    private func updateStatusFeedback() {
        switch status {
        case .requiresApproval:
            feedback = Feedback(
                message: "Approval is required in System Settings > General > Login Items.",
                tone: .information
            )
        case .notFound:
            feedback = Feedback(
                message: "Launch at Login is unavailable for this app build.",
                tone: .error
            )
        case .notRegistered, .enabled:
            feedback = nil
        }
    }
}
#endif
