import Foundation
import CryptoKit

/// Lowercase hex SHA-256 of `data` (CryptoKit; iOS 13 / macOS 10.15 and later).
func k9oSha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Thrown by `K9OJcs.canonicalize` for a value the platform's canonical form cannot hold.
public struct K9OJcsError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "K9OJcsError: \(message)" }
    public var errorDescription: String? { description }
}

/// The platform's canonical JSON form (the "Kilimanjaro JCS code-point profile").
///
/// - Object members are sorted by their names' UTF-8 bytes (the same as Unicode code point order), with no whitespace.
/// - Strings are escaped minimally: `"` and `\` with a backslash, the short escapes `\b \t \n \f \r`, every other
///   control character below U+0020 as lowercase `\u00xx`. `/` is not escaped and every other code point (U+2028 and
///   U+2029 included) is written as it is.
/// - Numbers are integers only, in base 10 without an exponent, `-0` as `0`. A fraction, `NaN`, an infinity or an
///   absolute value above 9007199254740991 (2^53 - 1) is refused.
public enum K9OJcs {
    static let maxSafeInteger = 9007199254740991.0

    /// The canonical JSON text of `value`. Throws `K9OJcsError` for a value that cannot be canonicalised.
    public static func canonicalize(_ value: K9OJSON) throws -> String {
        var out = ""
        try write(value, into: &out)
        return out
    }

    private static func write(_ value: K9OJSON, into out: inout String) throws {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += try number(n)
        case .string(let s): string(s, into: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                try write(v, into: &out)
            }
            out += "]"
        case .object(let o):
            let keys = o.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            out += "{"
            for (i, k) in keys.enumerated() {
                if i > 0 { out += "," }
                string(k, into: &out)
                out += ":"
                try write(o[k]!, into: &out)
            }
            out += "}"
        }
    }

    private static func number(_ n: Double) throws -> String {
        guard n.isFinite else { throw K9OJcsError("NaN and Infinity cannot be canonicalised") }
        guard n == n.rounded(.towardZero) else {
            throw K9OJcsError("only integers can be canonicalised; a fractional number is refused")
        }
        guard abs(n) <= maxSafeInteger else {
            throw K9OJcsError("an integer above 9007199254740991 in absolute value is refused")
        }
        return n == 0 ? "0" : String(Int64(n))
    }

    private static func string(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            case 0x00..<0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        out += "\""
    }
}
