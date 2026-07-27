#if os(macOS)
import Foundation
import IOKit.pwr_mgt

protocol KeepAwakeAssertionManaging {
    func createAssertion(reason: String) throws -> UInt32
    func releaseAssertion(_ assertionID: UInt32)
}

enum KeepAwakeControllerError: LocalizedError, Equatable {
    case assertionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .assertionFailed(let code):
            return "Could not keep this Mac awake. Power assertion failed with code \(code)."
        }
    }
}

struct SystemKeepAwakeAssertionManager: KeepAwakeAssertionManaging {
    func createAssertion(reason: String) throws -> UInt32 {
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            throw KeepAwakeControllerError.assertionFailed(result)
        }
        return UInt32(assertionID)
    }

    func releaseAssertion(_ assertionID: UInt32) {
        IOPMAssertionRelease(IOPMAssertionID(assertionID))
    }
}

final class KeepAwakeController {
    private let manager: KeepAwakeAssertionManaging
    private let reason: String
    private(set) var assertionID: UInt32?

    init(
        manager: KeepAwakeAssertionManaging = SystemKeepAwakeAssertionManager(),
        reason: String = "Glasstunnel remote access is keeping this Mac available"
    ) {
        self.manager = manager
        self.reason = reason
    }

    deinit {
        disable()
    }

    var isActive: Bool {
        assertionID != nil
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            disable()
        }
    }

    func enable() throws {
        guard assertionID == nil else { return }
        assertionID = try manager.createAssertion(reason: reason)
    }

    func disable() {
        guard let assertionID else { return }
        manager.releaseAssertion(assertionID)
        self.assertionID = nil
    }
}
#endif
