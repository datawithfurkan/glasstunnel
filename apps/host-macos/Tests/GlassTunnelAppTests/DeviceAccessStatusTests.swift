import XCTest
import GTSecurity
@testable import GlassTunnelApp

final class DeviceAccessStatusTests: XCTestCase {
    func testLocalDenialDoesNotClaimServerConfirmation() {
        var device = DeviceRegistry.PairedDevice(deviceId: "phone", publicKey: Data(), label: "Test")
        XCTAssertNil(DeviceAccessStatus(device: device, pending: false).title)
        device.revoked = true
        XCTAssertEqual(DeviceAccessStatus(device: device, pending: false), .blockedLocally)
        XCTAssertEqual(DeviceAccessStatus(device: device, pending: true), .pending)
        device.revocationConfirmedAt = Date()
        XCTAssertEqual(DeviceAccessStatus(device: device, pending: false).title, "Revoked")
    }
}
