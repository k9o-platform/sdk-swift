import Foundation

/// The address used when only an organization slug is given.
let k9oDefaultPlatformHost = "api.k9o.io"

func k9oIsValidOrgSlug(_ s: String) -> Bool {
    let b = Array(s.utf8)
    guard b.count >= 2, b.count <= 63, (0x61...0x7A).contains(b[0]), b.last != 0x2D else { return false }
    return b.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
}

/// Resolves the origin the client is built on from an optional base URL and an optional organization slug.
///
/// - A base URL whose host is a platform host with no organization and no region (`api.<apex>`, `api-staging.<apex>`)
///   plus an `orgSlug` gives `<scheme>://<orgSlug>.<host>` (port kept).
/// - Any other base URL (an organization host, a regional host, a custom domain, localhost, an IP) is used as given;
///   `orgSlug` is ignored.
/// - No base URL and an `orgSlug` gives `https://<orgSlug>.api.k9o.io`.
/// - Neither throws `K9O_INVALID_BASE_URL`; the bare platform address is never a default.
func k9oResolveBaseURL(_ baseURL: URL?, orgSlug: String?) throws -> URL {
    let slug = (orgSlug?.isEmpty == false) ? orgSlug : nil
    func checked(_ s: String) throws -> String {
        guard k9oIsValidOrgSlug(s) else {
            throw K9OError(
                code: K9OError.invalidFieldValue,
                message: "orgSlug does not match required format ^[a-z][a-z0-9-]{1,62}$ (must not end with '-')",
                context: .object(["field": .string("orgSlug"), "slug": .string(s)]),
                recommendation: "Pass a slug of lowercase letters, digits and hyphens, 2 to 63 characters, starting with a letter and not ending with a hyphen.")
        }
        return s
    }
    guard let baseURL else {
        guard let slug else {
            throw K9OError(code: K9OError.invalidBaseURL,
                           message: "Pass baseURL or orgSlug",
                           context: .object(["field": .string("baseUrl")]),
                           recommendation: "Pass the full organization address (https://<org>.api.k9o.io) as baseURL, or your organization slug as orgSlug.")
        }
        let s = try checked(slug)
        return URL(string: "https://\(s).\(k9oDefaultPlatformHost)")!
    }
    guard let slug, let host = baseURL.host, let scheme = baseURL.scheme,
          let parsed = K9OApiHost.parse(host), parsed.orgSlug == nil, parsed.region == nil else { return baseURL }
    let s = try checked(slug)
    let port = baseURL.port.map { ":\($0)" } ?? ""
    return URL(string: "\(scheme)://\(s).\(host.lowercased())\(port)") ?? baseURL
}
