import Foundation

struct AccountSignOutCoordinator<Identity> {
    struct Outcome {
        let remoteUnlinkConfirmed: Bool
        let replacementIdentity: Identity?
        let remoteUnlinkFailureDescription: String?
    }

    let clearTrustedDevices: () throws -> Void
    let rotateDeviceIdentity: () throws -> Identity

    func perform(remoteUnlink: (() async throws -> Void)?) async throws -> Outcome {
        var remoteUnlinkConfirmed = false
        var remoteUnlinkFailureDescription: String?

        if let remoteUnlink {
            do {
                try await remoteUnlink()
                remoteUnlinkConfirmed = true
            } catch {
                remoteUnlinkFailureDescription = error.localizedDescription
            }
        }

        try clearTrustedDevices()
        let replacementIdentity = try rotateDeviceIdentity()

        return Outcome(
            remoteUnlinkConfirmed: remoteUnlinkConfirmed,
            replacementIdentity: replacementIdentity,
            remoteUnlinkFailureDescription: remoteUnlinkFailureDescription
        )
    }
}
