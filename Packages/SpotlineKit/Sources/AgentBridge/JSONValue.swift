import Foundation

/// Any JSON value, for MCP messages and tool arguments and results.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    public var stringValue: String? {
        if case .string(let string) = self { string } else { nil }
    }

    public var boolValue: Bool? {
        if case .bool(let bool) = self { bool } else { nil }
    }

    public var doubleValue: Double? {
        if case .number(let number) = self { number } else { nil }
    }

    /// The number when it is a whole number.
    public var intValue: Int? {
        guard case .number(let number) = self, number.rounded() == number, abs(number) < 1e15 else { return nil }
        return Int(number)
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let array) = self { array } else { nil }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { object } else { nil }
    }

    /// Compact JSON with sorted keys, so output is stable.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding a JSONValue cannot fail: it holds only JSON types (and finite numbers).
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public var jsonString: String { String(decoding: encoded(), as: UTF8.self) }

    public static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .number(let number):
            // Whole numbers print without ".0", as JSON-RPC IDs and counts are expected to.
            if number.rounded() == number, abs(number) < 1e15 { try container.encode(Int64(number)) } else { try container.encode(number) }
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue {
    /// `.null` for nil, else the value.
    public init(_ string: String?) { self = string.map(JSONValue.string) ?? .null }
    public init(_ int: Int) { self = .number(Double(int)) }
    public init(_ int: Int64) { self = .number(Double(int)) }
    public init(_ double: Double) { self = .number(double) }
    public init(_ bool: Bool) { self = .bool(bool) }
}
