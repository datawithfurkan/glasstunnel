import Foundation

public enum ProtocolCodec {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dataEncodingStrategy = .base64
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dataDecodingStrategy = .base64
        return d
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    public static func encodeString<T: Encodable>(_ value: T) throws -> String {
        String(data: try encode(value), encoding: .utf8) ?? ""
    }

    public static func decodeString<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw NSError(domain: "ProtocolCodec", code: -1, userInfo: [NSLocalizedDescriptionKey: "not utf-8"])
        }
        return try decode(type, from: data)
    }
}
