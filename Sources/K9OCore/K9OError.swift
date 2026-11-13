import Foundation

/// Minimal JSON value, used for the open-shaped `context` of a KError.
public enum K9OJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([K9OJSON])
    case object([String: K9OJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([K9OJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: K9OJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// Platform error. Wire shape on non-2xx is FLAT: `{ code, message, context, recommendation }`.
/// Request bodies are never placed in the error text.
public struct K9OError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public let code: String
    public let message: String
    public let context: K9OJSON?
    public let recommendation: String?
    /// HTTP status, or nil when no response was received / the error is client-side.
    public let status: Int?
    /// Seconds the platform asks you to wait before retrying, when it says so.
    public let retryAfterSec: Double?
    /// The gateway's request id for the failed call (from the `x-k9o-request-id` response header), or nil.
    public let requestId: String?

    public init(code: String, message: String, context: K9OJSON? = nil, recommendation: String? = nil, status: Int? = nil,
                retryAfterSec: Double? = nil, requestId: String? = nil) {
        self.code = code
        self.message = message
        self.context = context
        self.recommendation = recommendation
        self.status = status
        self.retryAfterSec = retryAfterSec
        self.requestId = requestId
    }

    public var description: String { "K9OError(\(code)): \(message)" }
    public var errorDescription: String? { description }

    static let upstreamUnavailable = "K9O_UPSTREAM_UNAVAILABLE"
    static let internalError = "K9O_INTERNAL_ERROR"
    static let missingProjectContext = "K9O_MISSING_PROJECT_CONTEXT"
    static let invalidBaseURL = "K9O_INVALID_BASE_URL"
}

private struct K9OErrorWire: Decodable {
    let code: String
    let message: String?
    let context: K9OJSON?
    let recommendation: String?
    let retryAfterSec: Double?
    let requestId: String?

    private enum Keys: String, CodingKey { case code, message, context, recommendation, requestId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        code = try c.decode(String.self, forKey: .code)
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        context = try? c.decodeIfPresent(K9OJSON.self, forKey: .context)
        if let r = (try? c.decodeIfPresent(String.self, forKey: .requestId)) ?? nil, !r.isEmpty { requestId = r } else { requestId = nil }
        // `recommendation` is null, a string, or an object; any other shape reads as absent.
        var text: String?
        var wait: Double?
        if let raw = (try? c.decodeIfPresent(K9OJSON.self, forKey: .recommendation)) ?? nil {
            switch raw {
            case .string(let s): text = s
            case .object(let o):
                if case .string(let a)? = o["action"] { text = a }
                else if case .string(let n)? = o["note"] { text = n }
                if case .number(let n)? = o["retryAfterSec"], n.isFinite, n >= 0 { wait = n }
            default: break
            }
        }
        recommendation = text
        retryAfterSec = wait
    }
}

extension K9OError {
    /// `response` supplies the `x-k9o-request-id` header (any case) when the body carries no request id.
    static func fromResponse(status: Int, data: Data, response: HTTPURLResponse? = nil) -> K9OError {
        var header = response?.value(forHTTPHeaderField: "x-k9o-request-id")
        if let h = header, h.isEmpty { header = nil }
        if let w = try? JSONDecoder().decode(K9OErrorWire.self, from: data) {
            return K9OError(code: w.code, message: w.message ?? "", context: w.context,
                            recommendation: w.recommendation, status: status, retryAfterSec: w.retryAfterSec,
                            requestId: w.requestId ?? header)
        }
        return K9OError(code: internalError,
                        message: "Non-JSON error response (HTTP \(status))", status: status, requestId: header)
    }
}
