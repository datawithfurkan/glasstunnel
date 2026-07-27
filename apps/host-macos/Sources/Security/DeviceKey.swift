import CryptoKit
import Foundation
import GTProtocol

/// ed25519 device identity. Persisted in the macOS Keychain.
///
/// The `deviceId` is derived from the first 8 bytes of the public key as
/// `gt-<hex>`, matching the TypeScript `@glasstunnel/shared-crypto` derivation
/// exactly so phones and the Mac agree on identifiers.
public struct DeviceKey: @unchecked Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey
    public let publicKey: Curve25519.Signing.PublicKey
    public let deviceId: DeviceID

    public init() {
        let sk = Curve25519.Signing.PrivateKey()
        self.privateKey = sk
        self.publicKey = sk.publicKey
        self.deviceId = DeviceKey.deviceId(from: sk.publicKey)
    }

    public init(rawRepresentation: Data) throws {
        let sk = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
        self.privateKey = sk
        self.publicKey = sk.publicKey
        self.deviceId = DeviceKey.deviceId(from: sk.publicKey)
    }

    public func sign(_ message: Data) throws -> Data {
        try privateKey.signature(for: message)
    }

    public static func verify(signature: Data, message: Data, publicKey: Data) -> Bool {
        guard let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return pk.isValidSignature(signature, for: message)
    }

    public static func deviceId(from publicKey: Curve25519.Signing.PublicKey) -> DeviceID {
        let raw = publicKey.rawRepresentation
        return "gt-" + raw.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func deviceId(fromRawPublicKey raw: Data) -> DeviceID {
        "gt-" + raw.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public var publicKeyRaw: Data {
        publicKey.rawRepresentation
    }

    public var privateKeyRaw: Data {
        privateKey.rawRepresentation
    }
}
