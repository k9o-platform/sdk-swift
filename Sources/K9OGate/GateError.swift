import Foundation

/// Errors thrown by K9OGate SDK methods.
///
/// Maps the closed KError taxonomy from the gateway wire format.
/// The `.unknown` case carries the raw HTTP status code and optional
/// body text for diagnostics when the server returns an unrecognised
/// error code. Read `code`, `recommendation` and `retryAfterSec` for the
/// parsed fields, `requestId` for the gateway's request id, and `publicMessage` for text that is safe to show to users.
///
/// Each case that comes from a gateway response carries `requestId`: the value of the `x-k9o-request-id` response
/// header, or nil when the response has none. `.network` and `.decoding` have no response and no request id.
public enum K9OGateError: Error, Sendable {
    /// The session token is missing, expired, or revoked (HTTP 401).
    case unauthenticated(requestId: String?)
    /// The gateway ended the session (HTTP 401 `K9O_SESSION_EXPIRED`) and says why. The user must sign in again.
    case sessionEnded(reason: K9OSessionEndReason, requestId: String?)
    /// The caller lacks permission for the requested operation (HTTP 403).
    case forbidden(requestId: String?)
    /// Email/password (or other credential) did not match (HTTP 401 INVALID_CREDENTIALS).
    case invalidCredentials(requestId: String?)
    /// The step that finds the email's region is rate-limited (HTTP 429). Safe to retry.
    case rateLimited(statusCode: Int, body: String?, requestId: String?)
    /// The region that holds the email is unavailable (HTTP 503). Safe to retry after the hint in the body.
    case regionUnavailable(statusCode: Int, body: String?, requestId: String?)
    /// A transport-level failure — DNS, TCP, timeout, etc.
    case network(Error)
    /// The gateway response could not be decoded into the expected shape.
    case decoding(Error)
    /// Any other non-2xx status not covered by the cases above.
    case unknown(statusCode: Int, body: String?, requestId: String?)
}

/// Why the gateway ended a session, from `K9O_SESSION_EXPIRED`'s `context.reason`.
public enum K9OSessionEndReason: String, Sendable, Equatable {
    /// No refresh within the project's sign-out-after-inactivity limit.
    case inactive
    /// The session passed the project's maximum length.
    case maxLength = "max_length"
    /// The session was signed out or ended by a password reset, or the token followed a replay.
    case revoked
    /// An old refresh token was sent again. The gateway ended the session.
    case replay
}

/// How much of a gateway error the SDK keeps. Set with the `errors` option on `GateClient`.
public enum K9OGateErrorMode: String, Sendable, Equatable {
    /// Keep the gateway's code, recommendation and body. The default.
    case full
    /// Drop an unknown code, its body and its recommendation, and any other gateway text. A known code keeps its
    /// `code` and, for a rate limit or region outage, its `retryAfterSec`.
    case redacted
}

extension K9OGateError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthenticated, .sessionEnded:
            return "Session expired or not authenticated."
        case .forbidden:
            return "Access forbidden for the current session."
        case .invalidCredentials:
            return "Invalid credentials."
        case .rateLimited:
            return "Too many requests. Try again shortly."
        case .regionUnavailable:
            return "The region is unavailable. Try again shortly."
        case .network(let err):
            return "Network error: \(err.localizedDescription)"
        case .decoding(let err):
            return "Response decoding error: \(err.localizedDescription)"
        case .unknown(let code, let body, _):
            return "Unexpected error (HTTP \(code)): \(body ?? "<no body>")"
        }
    }
}

// MARK: - Accessors

extension K9OGateError {
    /// The HTTP status the gateway answered with. The typed cases without a status in their payload carry the status
    /// their wire code implies (401 for `.unauthenticated` and `.invalidCredentials`, 403 for `.forbidden`). Nil for
    /// `.network` and `.decoding`.
    public var statusCode: Int? {
        switch self {
        case .unauthenticated, .sessionEnded, .invalidCredentials: return 401
        case .forbidden: return 403
        case .rateLimited(let status, _, _), .regionUnavailable(let status, _, _), .unknown(let status, _, _): return status
        case .network, .decoding: return nil
        }
    }

    /// The request id the gateway sent in the `x-k9o-request-id` response header, for support and logs. Nil when the
    /// response had no such header, and for `.network` and `.decoding`, which have no response. Kept in redacted mode.
    public var requestId: String? {
        switch self {
        case .unauthenticated(let id), .forbidden(let id), .invalidCredentials(let id), .sessionEnded(_, let id): return id
        case .rateLimited(_, _, let id), .regionUnavailable(_, _, let id), .unknown(_, _, let id): return id
        case .network, .decoding: return nil
        }
    }

    /// Why the gateway ended the session: `.inactive`, `.maxLength`, `.revoked` or `.replay`. Nil for any other error.
    /// Kept in redacted mode. The user must sign in again.
    public var sessionEndReason: K9OSessionEndReason? {
        if case .sessionEnded(let reason, _) = self { return reason }
        return nil
    }

    /// The gateway's error code with its `K9O_` prefix, e.g. `K9O_MAGIC_LINK_REDIRECT_NOT_CONFIGURED`.
    ///
    /// Read from the body when the case holds one. Otherwise a typed case reports the code it stands for; for
    /// `.unauthenticated` that is `K9O_UNAUTHENTICATED`, although the gateway also sends `K9O_SESSION_EXPIRED` and
    /// `K9O_MISSING_TOKEN` for the same status. Nil for `.network`, `.decoding`, and an `.unknown` error whose body is
    /// absent or redacted.
    public var code: String? {
        if let wire = bodyFields?["code"] as? String, !wire.isEmpty { return wire }
        switch self {
        case .unauthenticated: return "K9O_UNAUTHENTICATED"
        case .sessionEnded: return "K9O_SESSION_EXPIRED"
        case .forbidden: return "K9O_FORBIDDEN"
        case .invalidCredentials: return "K9O_INVALID_CREDENTIALS"
        case .rateLimited: return "K9O_RATE_LIMITED"
        case .regionUnavailable: return "K9O_GATE_REGION_UNAVAILABLE"
        case .network, .decoding, .unknown: return nil
        }
    }

    /// The gateway's next step, as text. Read from `recommendation` in the body: a string is kept; an object gives its
    /// `action`, else its `note`. Nil when there is none or the body is absent or redacted.
    public var recommendation: String? {
        guard let raw = bodyFields?["recommendation"] else { return nil }
        if let text = raw as? String { return text }
        guard let object = raw as? [String: Any] else { return nil }
        if let action = object["action"] as? String { return action }
        return object["note"] as? String
    }

    /// Seconds the gateway asks the caller to wait before it retries, from `recommendation.retryAfterSec` in the body.
    /// Nil when the gateway sent none. Kept in redacted mode.
    public var retryAfterSec: Int? {
        guard let object = bodyFields?["recommendation"] as? [String: Any],
              let seconds = object["retryAfterSec"] as? Double, seconds.isFinite, seconds >= 0 else { return nil }
        return Int(seconds)
    }

    /// A fixed sentence chosen by status class, safe to show to an end user. It never contains the gateway's text.
    /// The same wording in every Gate client.
    public var publicMessage: String {
        switch self {
        case .network: return "Could not reach the service."
        default: break
        }
        switch statusCode ?? 0 {
        case 401, 403: return "You are not signed in or not allowed to do this."
        case 404: return "Not found."
        case 429: return "Too many attempts. Try again later."
        case 500...599: return "Something went wrong. Try again later."
        default: return "The request could not be completed."
        }
    }

    /// The JSON object in the body the case holds, if it parses.
    private var bodyFields: [String: Any]? {
        let text: String?
        switch self {
        case .rateLimited(_, let body, _), .regionUnavailable(_, let body, _), .unknown(_, let body, _): text = body
        case .unauthenticated, .sessionEnded, .forbidden, .invalidCredentials, .network, .decoding: text = nil
        }
        guard let data = text?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - Wire error envelope

/// The error object shape returned by the gateway on non-2xx responses.
/// The gateway emits a KError at the ROOT of the error body:
/// `{ code, message, context?, recommendation? }` — NOT wrapped in `{ error: … }`.
struct GateErrorWire: Decodable {
    let code: String
    let message: String?
}

extension K9OGateError {
    /// `requestId` is the `x-k9o-request-id` response header, read by the caller; nil when the response had none.
    static func from(statusCode: Int, data: Data, mode: K9OGateErrorMode = .full, requestId: String? = nil) -> K9OGateError {
        let body = mode == .full ? String(data: data, encoding: .utf8) : nil
        guard let wire = try? JSONDecoder().decode(GateErrorWire.self, from: data) else {
            return .unknown(statusCode: statusCode, body: body, requestId: requestId)
        }
        // Wire codes are platform-namespaced (`K9O_*`); strip the
        // prefix to match the typed cases.
        let code = wire.code.hasPrefix("K9O_") ? String(wire.code.dropFirst("K9O_".count)) : wire.code
        switch code {
        case "SESSION_EXPIRED":
            // The reason is one of four fixed words, so it is kept in both modes.
            let context = (try? JSONSerialization.jsonObject(with: data)) .flatMap { ($0 as? [String: Any])?["context"] as? [String: Any] }
            if let word = context?["reason"] as? String, let reason = K9OSessionEndReason(rawValue: word) {
                return .sessionEnded(reason: reason, requestId: requestId)
            }
            return .unauthenticated(requestId: requestId)
        case "UNAUTHENTICATED", "MISSING_TOKEN":
            return .unauthenticated(requestId: requestId)
        case "FORBIDDEN":
            return .forbidden(requestId: requestId)
        case "INVALID_CREDENTIALS":
            return .invalidCredentials(requestId: requestId)
        case "RATE_LIMITED":
            return .rateLimited(
                statusCode: statusCode, body: mode == .full ? body : redactedBody(data), requestId: requestId
            )
        case "GATE_REGION_UNAVAILABLE":
            return .regionUnavailable(
                statusCode: statusCode, body: mode == .full ? body : redactedBody(data), requestId: requestId
            )
        default:
            return .unknown(statusCode: statusCode, body: body, requestId: requestId)
        }
    }

    /// The body a redacted known error keeps: only the retry wait, when the gateway sent one.
    private static func redactedBody(_ data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let recommendation = object["recommendation"] as? [String: Any],
              let seconds = recommendation["retryAfterSec"] as? Double, seconds.isFinite, seconds >= 0 else { return nil }
        return "{\"recommendation\":{\"retryAfterSec\":\(Int(seconds))}}"
    }
}
