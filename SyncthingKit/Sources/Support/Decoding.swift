import Foundation

// Syncthing's REST API changes shape between versions. Every model decodes
// defensively: unknown keys are ignored (Codable default), missing or
// wrongly-typed keys fall back to a default instead of failing the payload.

extension KeyedDecodingContainer {
    /// Decodes `key` if present and well-typed, otherwise returns `fallback`.
    func lenient<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback()
    }

    /// Decodes an optional value, treating type mismatches as absent.
    func lenient<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// Numbers occasionally arrive as strings (and vice versa); accept both.
    func lenientInt(_ key: Key) -> Int {
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return Int(v) }
        if let s = try? decodeIfPresent(String.self, forKey: key), let v = Int(s) { return v }
        return 0
    }

    func lenientInt64(_ key: Key) -> Int64 {
        if let v = try? decodeIfPresent(Int64.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return Int64(v) }
        if let s = try? decodeIfPresent(String.self, forKey: key), let v = Int64(s) { return v }
        return 0
    }

    func lenientDouble(_ key: Key) -> Double {
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: key), let v = Double(s) { return v }
        return 0
    }

    func lenientBool(_ key: Key) -> Bool {
        if let v = try? decodeIfPresent(Bool.self, forKey: key) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s == "true" }
        return false
    }

    /// Syncthing timestamps (RFC 3339 with up to nanosecond precision).
    /// The Go zero time (`0001-01-01T00:00:00Z`) decodes as `nil`.
    func lenientDate(_ key: Key) -> Date? {
        guard let s = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        return SyncthingDate.parse(s)
    }
}

/// A string-keyed coding key usable for any JSON object.
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

public enum SyncthingDate {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let lock = NSLock()

    /// Parses RFC 3339 timestamps, truncating sub-millisecond precision that
    /// `ISO8601DateFormatter` cannot handle. Returns `nil` for Go's zero time.
    public static func parse(_ raw: String) -> Date? {
        if raw.isEmpty || raw.hasPrefix("0001-01-01") { return nil }
        var s = raw
        if let dot = s.firstIndex(of: ".") {
            let afterDot = s.index(after: dot)
            let digitsEnd = s[afterDot...].firstIndex(where: { !$0.isNumber }) ?? s.endIndex
            var digits = String(s[afterDot..<digitsEnd].prefix(3))
            while digits.count < 3 { digits += "0" }
            s = String(s[..<afterDot]) + digits + String(s[digitsEnd...])
        }
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: s) ?? plain.date(from: s)
    }
}

/// Arbitrary JSON, used where we must round-trip objects we don't fully model
/// (e.g. config defaults) without dropping unknown fields.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 9e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        get { if case .object(let o) = self { return o[key] } else { return nil } }
        set {
            guard case .object(var o) = self else { return }
            o[key] = newValue
            self = .object(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }

    /// Re-decodes this value as a concrete model.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
