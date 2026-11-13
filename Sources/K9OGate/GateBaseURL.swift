import Foundation

/// Thrown by `GateClient.init(orgBaseURL:orgSlug:projectSlug:...)` when the address cannot be resolved.
/// `code` is the platform error code.
public enum K9OGateConfigError: Error, Sendable, Equatable {
    /// Neither `orgBaseURL` nor `orgSlug` was given. Code `K9O_INVALID_BASE_URL`.
    case invalidBaseURL
    /// `orgSlug` does not match `^[a-z][a-z0-9-]{1,62}$` or ends with `-`. Code `K9O_INVALID_FIELD_VALUE`.
    case invalidFieldValue(field: String, slug: String)

    public var code: String {
        switch self {
        case .invalidBaseURL: return "K9O_INVALID_BASE_URL"
        case .invalidFieldValue: return "K9O_INVALID_FIELD_VALUE"
        }
    }

    /// Human-readable explanation, the same text as `errorDescription`.
    public var message: String {
        switch self {
        case .invalidBaseURL:
            return "Pass orgBaseURL or orgSlug."
        case .invalidFieldValue:
            return "orgSlug does not match required format ^[a-z][a-z0-9-]{1,62}$ (must not end with '-')."
        }
    }

    /// Names the offending input: `["field": "baseUrl"]` for a missing address, `["field": "orgSlug", "slug": <value>]`
    /// for a malformed slug.
    public var context: [String: String] {
        switch self {
        case .invalidBaseURL: return ["field": "baseUrl"]
        case .invalidFieldValue(let field, let slug): return ["field": field, "slug": slug]
        }
    }
}

extension K9OGateConfigError: LocalizedError {
    public var errorDescription: String? {
        message
    }
}

private func isValidOrgSlug(_ s: String) -> Bool {
    let b = Array(s.utf8)
    guard b.count >= 2, b.count <= 63, (0x61...0x7A).contains(b[0]), b.last != 0x2D else { return false }
    return b.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
}

/// Resolves the organization address from an optional base URL and an optional slug.
///
/// - A platform host with no organization and no region (`api.<apex>`, `api-staging.<apex>`) plus `orgSlug` gives
///   `<scheme>://<orgSlug>.<host>` (port kept).
/// - Any other base URL (organization host, regional host, custom domain, localhost, IP) is used as given.
/// - No base URL and an `orgSlug` gives `https://<orgSlug>.api.k9o.io`.
/// - Neither throws `.invalidBaseURL`; the bare platform address is never a default.
func gateResolveBaseURL(_ baseURL: URL?, orgSlug: String?) throws -> URL {
    let slug = (orgSlug?.isEmpty == false) ? orgSlug : nil
    func checked(_ s: String) throws -> String {
        guard isValidOrgSlug(s) else { throw K9OGateConfigError.invalidFieldValue(field: "orgSlug", slug: s) }
        return s
    }
    guard let baseURL else {
        guard let slug else { throw K9OGateConfigError.invalidBaseURL }
        return URL(string: "https://\(try checked(slug)).api.k9o.io")!
    }
    guard let slug, let host = baseURL.host, let scheme = baseURL.scheme,
          let parsed = GateApiHost.parse(host), parsed.orgSlug == nil, parsed.region == nil else { return baseURL }
    let s = try checked(slug)
    let port = baseURL.port.map { ":\($0)" } ?? ""
    return URL(string: "\(scheme)://\(s).\(host.lowercased())\(port)") ?? baseURL
}
