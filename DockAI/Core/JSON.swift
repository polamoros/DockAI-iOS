import Foundation

/// Any JSON value. Screens off the main path read the server's answers
/// through this rather than a mirror struct, so a field the server adds or
/// renames cannot stop the app decoding the rest.
enum JSON: Codable, Equatable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSON { if case .object(let o) = self { return o[key] ?? .null }; return .null }
    subscript(index: Int) -> JSON { if case .array(let a) = self, a.indices.contains(index) { return a[index] }; return .null }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var double: Double? { if case .number(let n) = self { return n }; return nil }
    var int: Int? { double.map { Int($0) } }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSON] { if case .array(let a) = self { return a }; return [] }
    var object: [String: JSON] { if case .object(let o) = self { return o }; return [:] }
    var isNull: Bool { self == .null }

    /// A date the server sent as an ISO string (superjson keeps dates as strings in `json`).
    var date: Date? {
        guard let s = string else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Build a JSON value from Swift literals for tRPC inputs.
    static func from(_ any: Any?) -> JSON {
        switch any {
        case nil: return .null
        case let v as JSON: return v
        case let v as Bool: return .bool(v)
        case let v as Int: return .number(Double(v))
        case let v as Double: return .number(v)
        case let v as String: return .string(v)
        case let v as [Any?]: return .array(v.map { from($0) })
        case let v as [String: Any?]: return .object(v.mapValues { from($0) })
        default: return .null
        }
    }
}
