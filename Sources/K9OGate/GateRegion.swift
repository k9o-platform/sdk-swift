import Foundation

/// Sends one request. Used for the credential-free region probe.
public typealias GateTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// Regional host resolution.
///
/// A region-free org host `<org>.api.<rest>` (or `<org>.api-staging.<rest>`) redirects GET/HEAD only and refuses a
/// request that carries a body or an `Authorization` header (400 `K9O_INVALID_REQUEST_SHAPE`). The client learns the
/// region with ONE credential-free `HEAD` to the configured host, takes the `308` `Location`, caches the regional
/// origin and sends every request there. A regional, single-label, IP, localhost or any other address is used exactly
/// as given and never probed.
struct GateApiHost: Equatable {
    let orgSlug: String?
    let family: String
    let region: String?
    let apex: String

    private static func isGateway(_ label: String) -> (String, String?)? {
        for family in ["api-staging", "api"] {
            if label == family { return (family, nil) }
            if label.hasPrefix(family + "-") {
                let r = String(label.dropFirst(family.count + 1))
                let b = Array(r.utf8)
                if b.count == 4, (0x61...0x7A).contains(b[0]), (0x61...0x7A).contains(b[1]),
                   (0x30...0x39).contains(b[2]), (0x30...0x39).contains(b[3]) { return (family, r) }
            }
        }
        return nil
    }

    private static func isSlug(_ s: String) -> Bool {
        guard let f = s.utf8.first, (0x61...0x7A).contains(f), s.utf8.count >= 2, s.utf8.count <= 63, !s.hasSuffix("-") else { return false }
        return s.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
    }

    static func parse(_ host: String) -> GateApiHost? {
        let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if labels.contains(where: { $0.isEmpty }) { return nil }
        if labels.count >= 3, let (fam, reg) = isGateway(labels[1]), isSlug(labels[0]) {
            return GateApiHost(orgSlug: labels[0], family: fam, region: reg, apex: labels.dropFirst(2).joined(separator: "."))
        }
        if labels.count >= 2, let (fam, reg) = isGateway(labels[0]) {
            return GateApiHost(orgSlug: nil, family: fam, region: reg, apex: labels.dropFirst().joined(separator: "."))
        }
        return nil
    }

    /// The regional origin a `Location` may name for `host`, or nil if it is not exactly that. Pure.
    static func regionalOrigin(host: String, location: String, base: URL) -> URL? {
        guard let from = parse(host), from.orgSlug != nil, from.region == nil else { return nil }
        guard let u = URL(string: location, relativeTo: base)?.absoluteURL,
              let c = URLComponents(url: u, resolvingAgainstBaseURL: true) else { return nil }
        guard c.scheme == "https", c.user == nil, c.password == nil, c.port == nil, let h = c.host else { return nil }
        guard let to = parse(h), to.region != nil, to.orgSlug == from.orgSlug, to.family == from.family,
              to.apex == from.apex else { return nil }
        return URL(string: "https://\(h.lowercased())")
    }
}

/// Learns and caches the origin requests go to. A definite answer is cached for the life of the client; a network
/// failure is not cached.
actor GateRegionResolver {
    private let configured: URL
    private let probeTransport: GateTransport
    private var resolved: URL?

    init(configured: URL, probeTransport: @escaping GateTransport) {
        self.configured = configured
        self.probeTransport = probeTransport
    }

    func origin() async -> URL {
        if let resolved { return resolved }
        guard let host = configured.host, configured.port == nil,
              let parsed = GateApiHost.parse(host), parsed.orgSlug != nil, parsed.region == nil else {
            resolved = configured
            return configured
        }
        var base = configured.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/") else { resolved = configured; return configured }
        // No credential and no default header: the probe is a bare HEAD.
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        do {
            let (_, response) = try await probeTransport(req)
            if let http = response as? HTTPURLResponse, http.statusCode == 308,
               let loc = http.value(forHTTPHeaderField: "Location"),
               let regional = GateApiHost.regionalOrigin(host: host, location: loc, base: configured) {
                resolved = regional
                return regional
            }
            resolved = configured
            return configured
        } catch {
            return configured
        }
    }
}

/// Session that reports redirects instead of following them, so the probe sees the 308.
final class GateNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The probe transport used when none is given: a session with the same configuration as `session` that reports
/// redirects instead of following them.
func gateDefaultProbeTransport(for session: URLSession) -> GateTransport {
    let configuration = session.configuration
    return { req in
        let probe = URLSession(configuration: configuration, delegate: GateNoRedirectDelegate(), delegateQueue: nil)
        defer { probe.finishTasksAndInvalidate() }
        return try await probe.data(for: req)
    }
}
