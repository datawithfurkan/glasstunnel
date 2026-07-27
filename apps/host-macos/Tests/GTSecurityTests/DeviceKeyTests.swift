import XCTest
@testable import GTSecurity
@testable import GTProtocol

final class DeviceKeyTests: XCTestCase {
    func testDeriveDeviceID() {
        let key = DeviceKey()
        XCTAssertTrue(key.deviceId.hasPrefix("gt-"))
        XCTAssertEqual(key.deviceId.count, 3 + 16) // "gt-" + 16 hex chars
    }

    func testPersistenceRoundTrip() throws {
        let key = DeviceKey()
        let raw = key.privateKeyRaw
        let rehydrated = try DeviceKey(rawRepresentation: raw)
        XCTAssertEqual(key.deviceId, rehydrated.deviceId)
        XCTAssertEqual(key.publicKeyRaw, rehydrated.publicKeyRaw)
    }

    func testDeviceKeyStoreUsesDefaultKeychainAccountWithoutSuffix() {
        XCTAssertEqual(
            DeviceKeyStore.resolveHostKeyAccount(environment: [:]),
            "host.private_key"
        )
    }

    func testDeviceKeyStoreCanUseSmokeKeychainAccountSuffix() {
        XCTAssertEqual(
            DeviceKeyStore.resolveHostKeyAccount(environment: ["GLASSTUNNEL_KEYCHAIN_SUFFIX": "smoke"]),
            "host.private_key.smoke"
        )
    }

    func testDeviceKeyStoreSanitizesKeychainAccountSuffix() {
        XCTAssertEqual(
            DeviceKeyStore.resolveHostKeyAccount(environment: ["GLASSTUNNEL_KEYCHAIN_SUFFIX": "smoke test/account"]),
            "host.private_key.smoke_test_account"
        )
    }

    func testDeviceKeyStoreUsesKeychainOutsideDevMode() {
        XCTAssertNil(DeviceKeyStore.resolveDevKeyFileURL(environment: [:]))
    }

    func testDeviceKeyStoreUsesDevFileInDevMode() throws {
        let url = try XCTUnwrap(DeviceKeyStore.resolveDevKeyFileURL(environment: ["GLASSTUNNEL_DEV": "1"]))
        XCTAssertTrue(url.path.contains("/Glasstunnel/DevKeys/"))
        XCTAssertEqual(url.lastPathComponent, "host.private_key.key")
    }

    func testDeviceKeyStoreDevFileRoundTripAndReset() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("glasstunnel-device-key-\(UUID().uuidString).key")
        let environment = [
            "GLASSTUNNEL_DEV_DEVICE_KEY_FILE": tmp.path
        ]

        let firstStore = DeviceKeyStore(environment: environment)
        let first = try firstStore.getOrCreate()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))

        let secondStore = DeviceKeyStore(environment: environment)
        let second = try secondStore.getOrCreate()
        XCTAssertEqual(first.deviceId, second.deviceId)

        try secondStore.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
    }

    func testSignVerifyRoundTrip() throws {
        let key = DeviceKey()
        let msg = Data("hello glasstunnel".utf8)
        let sig = try key.sign(msg)
        XCTAssertTrue(DeviceKey.verify(signature: sig, message: msg, publicKey: key.publicKeyRaw))
    }

    func testVerifyRejectsTamperedMessage() throws {
        let key = DeviceKey()
        let sig = try key.sign(Data("hello".utf8))
        XCTAssertFalse(DeviceKey.verify(signature: sig, message: Data("HELLO".utf8), publicKey: key.publicKeyRaw))
    }

    func testVerifyRejectsWrongKey() throws {
        let a = DeviceKey()
        let b = DeviceKey()
        let msg = Data("hello".utf8)
        let sig = try a.sign(msg)
        XCTAssertFalse(DeviceKey.verify(signature: sig, message: msg, publicKey: b.publicKeyRaw))
    }

    func testEnvelopeSigningRoundTrip() throws {
        let key = DeviceKey()
        let env = Envelope(
            envelopeId: "env-1",
            fromDeviceId: key.deviceId,
            toDeviceId: "gt-phone",
            sentAtUnixMs: 1234,
            payload: .ping(Ping(atUnixMs: 1234))
        )

        let signed = try env.signed(using: key)

        XCTAssertFalse(signed.signature.isEmpty)
        XCTAssertTrue(signed.hasValidSignature(publicKey: key.publicKeyRaw))
    }

    func testEnvelopeSignatureRejectsTampering() throws {
        let key = DeviceKey()
        let signed = try Envelope(
            envelopeId: "env-1",
            fromDeviceId: key.deviceId,
            toDeviceId: "gt-phone",
            sentAtUnixMs: 1234,
            payload: .ping(Ping(atUnixMs: 1234))
        ).signed(using: key)
        let tampered = Envelope(
            envelopeId: signed.envelopeId,
            fromDeviceId: signed.fromDeviceId,
            toDeviceId: "gt-other",
            sentAtUnixMs: signed.sentAtUnixMs,
            signature: signed.signature,
            payload: signed.payload
        )

        XCTAssertFalse(tampered.hasValidSignature(publicKey: key.publicKeyRaw))
    }
}
