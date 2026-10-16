import Foundation

// The Python client decoded with pydantic's lax mode, which accepts 0/1 for bools.
// The device's firmware is not guaranteed to send strict JSON booleans, so match that.

@propertyWrapper
public struct LenientBool: Decodable, Sendable, Equatable {
    public var wrappedValue: Bool

    public init(wrappedValue: Bool) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            wrappedValue = value
        } else if let value = try? container.decode(Int.self) {
            wrappedValue = value != 0
        } else if let value = try? container.decode(String.self) {
            switch value.lowercased() {
            case "true", "1", "yes", "on": wrappedValue = true
            case "false", "0", "no", "off", "": wrappedValue = false
            default:
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a boolean: \(value)")
            }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a boolean")
        }
    }
}

@propertyWrapper
public struct LenientOptionalBool: Decodable, Sendable, Equatable {
    public var wrappedValue: Bool?

    public init(wrappedValue: Bool?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        wrappedValue = try LenientBool(from: decoder).wrappedValue
    }
}

extension KeyedDecodingContainer {
    // Lets a missing key decode as nil for the optional wrapper, like a plain `Bool?` would.
    func decode(_ type: LenientOptionalBool.Type, forKey key: Key) throws -> LenientOptionalBool {
        try decodeIfPresent(type, forKey: key) ?? LenientOptionalBool(wrappedValue: nil)
    }
}

/// Arbitrary JSON, for the device fields the Python client left as `Dict[str, Any]`.
public enum JSONValue: Decodable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
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
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(exactly: value) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
