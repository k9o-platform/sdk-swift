import Foundation

// Locating the end user's region for password sign-in.
//
// `GateRegion.swift` finds the org's regional API host. An end user can live in another region of the project, so
// sign-in first asks the project which region holds the address (`POST /@<projectSlug>/gate/locate { email }` at that
// regional base) and sends the credential to the origin it names. The answer is the same for a known and an unknown
// address.
//
// Rules:
//   - The located origin is used for that one attempt. It is never cached as authority. The one thing kept is a hint,
//     per refresh token, so that refresh and sign-out reach the region that issued the session; a stale hint gets a 401.
//   - An origin is used only if it is `https` (`http` only when the base is itself `http` on a loopback host), has no
//     userinfo, port, path, query or fragment, and its host is exactly the base host's org, family and apex with the
//     region code `[a-z]{2}\d{2}` added or swapped in the service label, and that code equals the answer's `region`.
//     Anything else, or `origin: null`, means the base is used. A password never goes to a host that fails this.

/// Request body of the locate door: the email only.
struct LocateBody: Encodable {
    let email: String
}

/// The `data` of the locate answer. A field of the wrong type reads as absent, which means the base is used.
struct LocateAnswer: Decodable {
    let region: String?
    let origin: String?

    private enum CodingKeys: String, CodingKey { case region, origin }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        region = try? c.decode(String.self, forKey: .region)
        origin = try? c.decode(String.self, forKey: .origin)
    }
}

private func isLoopback(_ host: String) -> Bool {
    let h = host.lowercased()
    return h == "localhost" || h.hasSuffix(".localhost") || h == "127.0.0.1" || h == "::1" || h == "[::1]"
}

private func isRegionCode(_ s: String) -> Bool {
    let b = Array(s.utf8)
    return b.count == 4 && (0x61...0x7A).contains(b[0]) && (0x61...0x7A).contains(b[1])
        && (0x30...0x39).contains(b[2]) && (0x30...0x39).contains(b[3])
}

/// The origin the credential goes to: the located one if it passes the rule, else `base`. Pure; never fails.
/// `region` and `origin` are the fields of the locate answer's `data`.
func chooseLocatedOrigin(base: URL, region: String?, origin: String?) -> URL {
    guard let region, let origin, isRegionCode(region),
          let b = URLComponents(url: base, resolvingAgainstBaseURL: false),
          let u = URLComponents(string: origin),
          let bScheme = b.scheme?.lowercased(), let uScheme = u.scheme?.lowercased(),
          let bHost = b.host?.lowercased(), let uHost = u.host?.lowercased() else { return base }
    if u.user != nil || u.password != nil || u.port != nil || u.query != nil || u.fragment != nil { return base }
    if !u.path.isEmpty && u.path != "/" { return base }
    if uScheme != "https" && !(uScheme == "http" && bScheme == "http" && isLoopback(bHost) && isLoopback(uHost)) {
        return base
    }
    if uScheme == bScheme && uHost == bHost && b.port == nil { return base }
    guard let from = GateApiHost.parse(bHost), let to = GateApiHost.parse(uHost), to.region == region else { return base }
    guard from.orgSlug == to.orgSlug, from.family == to.family, from.apex == to.apex else { return base }
    return URL(string: "\(uScheme)://\(uHost)") ?? base
}

/// Per-refresh-token origin hints, bounded to `limit`; oldest dropped first. A hint, never authority.
final class SessionOrigins: @unchecked Sendable {
    static let shared = SessionOrigins()
    static let limit = 64

    private let lock = NSLock()
    private var order: [String] = []
    private var hints: [String: URL] = [:]

    /// Remember which origin issued the session with this refresh token.
    func remember(_ refreshToken: String?, _ origin: URL) {
        guard let refreshToken, !refreshToken.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        order.removeAll { $0 == refreshToken }
        order.append(refreshToken)
        hints[refreshToken] = origin
        while order.count > SessionOrigins.limit { hints[order.removeFirst()] = nil }
    }

    func hint(_ refreshToken: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return hints[refreshToken]
    }

    func forget(_ refreshToken: String) {
        lock.lock(); defer { lock.unlock() }
        order.removeAll { $0 == refreshToken }
        hints[refreshToken] = nil
    }
}
