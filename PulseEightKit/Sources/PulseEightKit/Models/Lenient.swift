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

// MARK: - Keys that differ between firmware versions

/// A coding key made of whatever the device sent, so a struct can look its fields up by name without
/// caring how the firmware spelled them.
struct LooseKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Reads an object's fields ignoring case and underscores: `Revision` and `revision`, `HdbtUpgrade` and
/// `hdbt_upgrade`, `Ir` and `IR`. A real NeoMatrix (firmware 3.10) spells these differently from the vendor
/// library's models this app was first written from, and one wrongly spelled key used to stop all of the
/// system information from loading.
///
/// Lookups are forgiving: a field that is missing, or present with a value of the wrong type, gives the
/// default. Hardware details are for display, and one odd value shouldn't hide the rest.
struct LooseObject {
    private let container: KeyedDecodingContainer<LooseKey>

    init(_ decoder: Decoder) throws {
        container = try decoder.container(keyedBy: LooseKey.self)
    }

    private static func normalised(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "_", with: "")
    }

    private func key(_ name: String) -> LooseKey? {
        let wanted = Self.normalised(name)
        return container.allKeys.first { Self.normalised($0.stringValue) == wanted }
    }

    func has(_ name: String) -> Bool { key(name) != nil }

    /// The names the device sent, as it spelled them.
    var keys: [String] { container.allKeys.map(\.stringValue) }

    /// The value, or nil if the field is missing or not a `T`.
    func value<T: Decodable>(_ name: String, as type: T.Type = T.self) -> T? {
        guard let key = key(name) else { return nil }
        return try? container.decode(T.self, forKey: key)
    }

    func value<T: Decodable>(_ name: String, default fallback: T) -> T {
        value(name) ?? fallback
    }

    /// A boolean the device may send as true/false, 0/1 or text.
    func bool(_ name: String, default fallback: Bool = false) -> Bool {
        bool(name) ?? fallback
    }

    func bool(_ name: String) -> Bool? {
        guard let key = key(name) else { return nil }
        return (try? container.decode(LenientBool.self, forKey: key))?.wrappedValue
    }

    /// An object nested under `name`, read the same loose way.
    func object(_ name: String) -> LooseObject? {
        guard let key = key(name), let nested = try? container.superDecoder(forKey: key) else { return nil }
        return try? LooseObject(nested)
    }
}
