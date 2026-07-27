import Foundation
import GTProtocol

private struct EnvelopeSigningMaterial: Encodable {
    let envelopeId: String
    let fromDeviceId: DeviceID
    let toDeviceId: DeviceID
    let sentAtUnixMs: Int64
    let payload: Envelope.Payload
}

public extension Envelope {
    func signingData() throws -> Data {
        try ProtocolCodec.encode(EnvelopeSigningMaterial(
            envelopeId: envelopeId,
            fromDeviceId: fromDeviceId,
            toDeviceId: toDeviceId,
            sentAtUnixMs: sentAtUnixMs,
            payload: payload
        ))
    }

    func signed(using key: DeviceKey) throws -> Envelope {
        var copy = self
        copy.signature = try key.sign(copy.signingData())
        return copy
    }

    func hasValidSignature(publicKey: Data) -> Bool {
        guard !signature.isEmpty else { return false }
        guard let data = try? signingData() else { return false }
        return DeviceKey.verify(signature: signature, message: data, publicKey: publicKey)
    }
}
