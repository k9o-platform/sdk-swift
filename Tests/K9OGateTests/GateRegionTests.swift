import XCTest
@testable import K9OGate

final class GateRegionTests: XCTestCase {
    final class Probes: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
        func add(_ r: URLRequest) { lock.lock(); _requests.append(r); lock.unlock() }
    }

    var session: URLSession!

    override func setUp() async throws {
        StubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() async throws { StubURLProtocol.reset() }

    private func redirect(_ url: URL, to location: String?, status: Int = 308) -> (Data, URLResponse) {
        let fields = location.map { ["Location": $0] } ?? [:]
        return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!)
    }

    private func client(_ base: String, probes: Probes, location: String?, fail: Bool = false) -> GateClient {
        GateClient(
            orgBaseURL: URL(string: base)!,
            projectSlug: "test-project",
            tokenStore: nil,
            urlSession: session,
            probeTransport: { [self] req in
                probes.add(req)
                if fail { throw URLError(.notConnectedToInternet) }
                return redirect(req.url!, to: location)
            }
        )
    }

    private func registerSignIn(_ seen: Probes) {
        StubURLProtocol.register(method: "POST", pathSuffix: "signin") { req in
            seen.add(req)
            return (200, authResultEnvelope())
        }
    }

    func testShortAddressProbesOnceThenSignInGoesToRegionalHostWithBody() async throws {
        let probes = Probes(), sent = Probes()
        registerSignIn(sent)
        let gate = client("https://acme.api.k9o.io", probes: probes, location: "https://acme.api-de01.k9o.io/")
        _ = try await gate.signIn(email: "user@example.com", password: "pass")
        _ = try await gate.signIn(email: "user@example.com", password: "pass")

        XCTAssertEqual(probes.requests.count, 1)
        let probe = probes.requests[0]
        XCTAssertEqual(probe.httpMethod, "HEAD")
        XCTAssertEqual(probe.url?.host, "acme.api.k9o.io")
        XCTAssertNil(probe.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(probe.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertNil(probe.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertNil(probe.httpBody)

        XCTAssertEqual(sent.requests.count, 2)
        XCTAssertEqual(sent.requests[0].url?.absoluteString, "https://acme.api-de01.k9o.io/@test-project/gate/signin")
        let body = try JSONSerialization.jsonObject(with: sent.requests[0].httpBody ?? Data()) as? [String: String]
        XCTAssertEqual(body, ["email": "user@example.com", "password": "pass"])
    }

    func testStagingFamilyIsFollowed() async throws {
        let probes = Probes(), sent = Probes()
        registerSignIn(sent)
        let gate = client("https://acme.api-staging.k9o.io", probes: probes, location: "https://acme.api-staging-de01.k9o.io/")
        _ = try await gate.signIn(email: "a@b.co", password: "p")
        XCTAssertEqual(sent.requests.first?.url?.host, "acme.api-staging-de01.k9o.io")
    }

    func testRegionalAddressIsUsedAsGivenWithoutProbe() async throws {
        let probes = Probes(), sent = Probes()
        registerSignIn(sent)
        let gate = client("https://acme.api-de01.k9o.io", probes: probes, location: "https://evil.example/")
        _ = try await gate.signIn(email: "a@b.co", password: "p")
        XCTAssertEqual(probes.requests.count, 0)
        XCTAssertEqual(sent.requests.first?.url?.host, "acme.api-de01.k9o.io")
    }

    func testLocalhostIpAndOtherHostsAreNotProbed() async throws {
        for base in ["http://localhost:3000", "https://127.0.0.1:8443", "https://gateway", "https://example.com"] {
            let probes = Probes(), sent = Probes()
            StubURLProtocol.reset()
            registerSignIn(sent)
            let gate = client(base, probes: probes, location: "https://acme.api-de01.k9o.io/")
            _ = try await gate.signIn(email: "a@b.co", password: "p")
            XCTAssertEqual(probes.requests.count, 0, base)
            XCTAssertEqual(sent.requests.first?.url?.host, URL(string: base)!.host, base)
        }
    }

    func testHostileLocationsAreIgnored() async throws {
        let hostile = [
            "http://acme.api-de01.k9o.io/",
            "https://evil.example/",
            "https://other.api-de01.k9o.io/",
            "https://acme.api-de01.k9o.io.evil.example/",
            "https://acme.api-de01.k9o.com/",
            "https://acme.api-staging-de01.k9o.io/",
            "https://user:pw@acme.api-de01.k9o.io/",
            "https://acme.api-de01.k9o.io:8443/",
            "https://acme.api.k9o.io/",
        ]
        for location in hostile {
            let probes = Probes(), sent = Probes()
            StubURLProtocol.reset()
            registerSignIn(sent)
            let gate = client("https://acme.api.k9o.io", probes: probes, location: location)
            _ = try await gate.signIn(email: "a@b.co", password: "p")
            XCTAssertEqual(sent.requests.first?.url?.host, "acme.api.k9o.io", location)
        }
    }

    func testProbeFailureIsNotCachedAndNextCallProbesAgain() async throws {
        let probes = Probes(), sent = Probes()
        registerSignIn(sent)
        let failing = client("https://acme.api.k9o.io", probes: probes, location: nil, fail: true)
        _ = try await failing.signIn(email: "a@b.co", password: "p")
        _ = try await failing.signIn(email: "a@b.co", password: "p")
        XCTAssertEqual(probes.requests.count, 2)

        // Resolver level: a failure is followed by a definite answer that is then cached.
        let flaky = Probes()
        let resolver = GateRegionResolver(configured: URL(string: "https://acme.api.k9o.io")!) { req in
            flaky.add(req)
            if flaky.requests.count == 1 { throw URLError(.timedOut) }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 308, httpVersion: "HTTP/1.1",
                                            headerFields: ["Location": "https://acme.api-de01.k9o.io/"])!)
        }
        let first = await resolver.origin()
        let second = await resolver.origin()
        let third = await resolver.origin()
        XCTAssertEqual(first.host, "acme.api.k9o.io")
        XCTAssertEqual(second.host, "acme.api-de01.k9o.io")
        XCTAssertEqual(third.host, "acme.api-de01.k9o.io")
        XCTAssertEqual(flaky.requests.count, 2)
    }

    func testNonRedirectAnswerIsCachedAsGiven() async throws {
        let probes = Probes(), sent = Probes()
        registerSignIn(sent)
        let gate = client("https://acme.api.k9o.io", probes: probes, location: nil)
        _ = try await gate.signIn(email: "a@b.co", password: "p")
        _ = try await gate.signIn(email: "a@b.co", password: "p")
        XCTAssertEqual(probes.requests.count, 1)
        XCTAssertEqual(sent.requests.first?.url?.host, "acme.api.k9o.io")
    }

    func testRefreshAndSignOutUseTheRegionalHost() async throws {
        let probes = Probes(), sent = Probes()
        StubURLProtocol.register(method: "POST", pathSuffix: "refresh") { req in sent.add(req); return (200, refreshEnvelope()) }
        StubURLProtocol.register(method: "POST", pathSuffix: "signout") { req in
            sent.add(req); return (200, jsonData(["data": ["revoked": true], "meta": [:]]))
        }
        let gate = client("https://acme.api.k9o.io", probes: probes, location: "https://acme.api-de01.k9o.io/")
        _ = try await gate.refreshToken(refreshToken: "rt_x")
        _ = try await gate.signOut(refreshToken: "rt_x")
        XCTAssertEqual(probes.requests.count, 1)
        XCTAssertEqual(sent.requests.map { $0.url?.host }, ["acme.api-de01.k9o.io", "acme.api-de01.k9o.io"])
    }
}
