// JSONValue.swift
// Majoor — A typed JSON tree
//
// Frames on the control API carry heterogeneous bodies; JSON-RPC results
// from bridges do too. This is the Sendable, Codable alternative to
// [String: Any] for those payloads.

import Foundation

nonisolated indirect enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value):
            if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Accessors

    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    var intValue: Int? { if case .number(let n) = self, n == n.rounded() { return Int(n) }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    // MARK: Bridging

    /// From the objects JSONSerialization produces.
    init(any: Any) throws {
        switch any {
        case is NSNull: self = .null
        case let number as NSNumber:
            // JSONSerialization represents booleans as NSNumber with the CFBoolean type.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) } else { self = .number(number.doubleValue) }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(try array.map { try JSONValue(any: $0) })
        case let dict as [String: Any]: self = .object(try dict.mapValues { try JSONValue(any: $0) })
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported JSON object \(type(of: any))"))
        }
    }

    init(data: Data) throws {
        self = try JSONDecoder.wire.decode(JSONValue.self, from: data)
    }

    func data() throws -> Data {
        try JSONEncoder.wire.encode(self)
    }

    /// Any Encodable, as a tree.
    static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder.wire.decode(JSONValue.self, from: JSONEncoder.wire.encode(value))
    }

    /// This tree, as a typed value.
    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder.wire.decode(T.self, from: JSONEncoder.wire.encode(self))
    }
}

extension JSONEncoder {
    /// The one encoder every wire format uses: ISO 8601 dates, sorted keys.
    nonisolated static var wire: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    nonisolated static var wire: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
