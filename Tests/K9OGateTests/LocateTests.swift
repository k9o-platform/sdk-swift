import XCTest
@testable import K9OGate

/// The locate door: password sign-in asks the project which region holds the address, and sends the credential only to
/// an origin that passes the rule in `Locate.swift`.
final class LocateTests: XCTestCase {
    let base = URL(string: "https://acme.api-de01.k9o.io")!

    // MARK: - The rule

    private func pick(_ region: String?, _ origin: String?, base: String? = nil) -> String {
        chooseLocatedOrigin(base: base.flatMap { URL(string: $0) } ?? self.base, region: region, origin: origin).absoluteString
    }

    func testUsesAcceptedOrigins() {
        XCTAssertEqual(pick("us01", "https://acme.api-us01.k9o.io"), "https://acme.api-us01.k9o.io")
        XCTAssertEqual(pick("de01", base.absoluteString), base.absoluteString)
        XCTAssertEqual(pick("us01", "https://acme.api-us01.k9o.io/"), "https://acme.api-us01.k9o.io")
    }

    func testFallsBackToTheBaseForEveryOriginThatFailsTheRule() {
        let refused: [(String, String?, String?)] = [
            ("null origin (single host, self-hosted)", "de01", nil),
            ("a missing answer", nil, nil),
            ("http", "us01", "http://acme.api-us01.k9o.io"),
            ("userinfo", "us01", "https://u:p@acme.api-us01.k9o.io"),
            ("a port", "us01", "https://acme.api-us01.k9o.io:8443"),
            ("a path", "us01", "https://acme.api-us01.k9o.io/x"),
            ("a query", "us01", "https://acme.api-us01.k9o.io/?a=1"),
            ("a fragment", "us01", "https://acme.api-us01.k9o.io/#x"),
            ("another org", "us01", "https://evil.api-us01.k9o.io"),
            ("another apex", "us01", "https://acme.api-us01.evil.io"),
            ("another family", "us01", "https://acme.api-staging-us01.k9o.io"),
            ("a code that differs from region", "us01", "https://acme.api-fr01.k9o.io"),
            ("a region that is not a code", "usa", "https://acme.api-usa.k9o.io"),
            ("a host with no region", "us01", "https://acme.api.k9o.io"),
            ("a region as a subdomain", "us01", "https://us01.acme.api-de01.k9o.io"),
            ("a look-alike apex", "us01", "https://acme.api-us01.k9o.io.evil.io"),
            ("an origin that is not a URL", "us01", "not a url"),
        ]
        for (name, region, origin) in refused {
            XCTAssertEqual(pick(region, origin), base.absoluteString, name)
        }
    }

    func testAllowsHttpOnlyWhenTheBaseIsHttpOnLoopbackAndThenOnlyTheSameHost() {
        XCTAssertEqual(pick("de01", "http://localhost:8080", base: "http://localhost:8080"), "http://localhost:8080")
        XCTAssertEqual(pick("de01", "http://evil.localhost:8080", base: "http://localhost:8080"), "http://localhost:8080")
        XCTAssertEqual(pick("de01", "http://localhost", base: "https://localhost"), "https://localhost")
        XCTAssertEqual(pick("de01", "http://localhost", base: "http://localhost"), "http://localhost")
    }

    func testUsesTheBaseWhenTheBaseIsNotAGatewayHostShape() {
        XCTAssertEqual(
            pick("us01", "https://gw-us01.internal.example", base: "https://gw.internal.example"),
            "https://gw.internal.example"
        )
    }

    // MARK: - The flow

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
        var urls: [String] { requests.map { $0.url!.absoluteString } }
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

    private func gate() -> GateClient {
        GateClient(orgBaseURL: base, projectSlug: "portal", tokenStore: nil, urlSession: session)
    }

    private func door(_ seen: Seen, region: String, origin: String?) {
        StubURLProtocol.register(method: "POST", pathSuffix: "locate") { req in
            seen.add(req)
            let data: [String: Any] = ["region": region, "origin": origin as Any? ?? NSNull()]
            return (200, jsonData(["data": data, "meta": [:]]))
        }
    }

    private func credential(_ seen: Seen) {
        StubURLProtocol.register(method: "POST", pathSuffix: "signin") { req in
            seen.add(req)
            return (200, authResultEnvelope())
        }
        StubURLProtocol.register(method: "POST", pathSuffix: "refresh") { req in
            seen.add(req)
            return (200, refreshEnvelope())
        }
        StubURLProtocol.register(method: "POST", pathSuffix: "signout") { req in
            seen.add(req)
            return (200, jsonData(["data": ["revoked": true], "meta": [:]]))
        }
    }

    private func body(_ r: URLRequest) -> [String: String]? {
        let data = r.httpBody ?? Data()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    func testSendsOnlyTheEmailToTheDoorThenThePasswordToTheLocatedOrigin() async throws {
        let seen = Seen()
        door(seen, region: "us01", origin: "https://acme.api-us01.k9o.io")
        credential(seen)
        _ = try await gate().signIn(email: "a@b.co", password: "pw")
        XCTAssertEqual(seen.urls, [
            "https://acme.api-de01.k9o.io/@portal/gate/locate",
            "https://acme.api-us01.k9o.io/@portal/gate/signin",
        ])
        XCTAssertEqual(body(seen.requests[0]), ["email": "a@b.co"])
        XCTAssertNil(seen.requests[0].value(forHTTPHeaderField: "Authorization"))
    }

    func testNeverSendsThePasswordToAnOriginThatFailsTheRule() async throws {
        let seen = Seen()
        door(seen, region: "us01", origin: "https://evil.example")
        credential(seen)
        _ = try await gate().signIn(email: "a@b.co", password: "pw")
        XCTAssertEqual(seen.urls[1], "https://acme.api-de01.k9o.io/@portal/gate/signin")
        XCTAssertFalse(seen.urls.contains { $0.contains("evil.example") })
    }

    func testUsesTheBaseWhenTheDoorAnswersOriginNull() async throws {
        let seen = Seen()
        door(seen, region: "de01", origin: nil)
        credential(seen)
        _ = try await gate().signIn(email: "a@b.co", password: "pw")
        XCTAssertEqual(seen.urls[1], "https://acme.api-de01.k9o.io/@portal/gate/signin")
    }

    func testUsesTheBaseWhenTheDoorAnswers2xxWithAMalformedBody() async throws {
        for bad in ["not-json", "{}", "null"] {
            StubURLProtocol.reset()
            let seen = Seen()
            StubURLProtocol.register(method: "POST", pathSuffix: "locate") { req in
                seen.add(req)
                return (200, Data(bad.utf8))
            }
            credential(seen)
            _ = try await gate().signIn(email: "a@b.co", password: "pw")
            XCTAssertEqual(seen.urls, [
                "https://acme.api-de01.k9o.io/@portal/gate/locate",
                "https://acme.api-de01.k9o.io/@portal/gate/signin",
            ], bad)
        }
    }

    func testSendsNothingToSignInWhenTheDoorIsDownOrRateLimitedAndThrowsTheDoorsError() async throws {
        for (status, code) in [(503, "K9O_GATE_REGION_UNAVAILABLE"), (429, "K9O_RATE_LIMITED")] {
            StubURLProtocol.reset()
            let seen = Seen()
            StubURLProtocol.register(method: "POST", pathSuffix: "locate") { req in
                seen.add(req)
                return (status, errorEnvelope(code: code))
            }
            credential(seen)
            do {
                _ = try await gate().signIn(email: "a@b.co", password: "pw")
                XCTFail("expected a thrown error for \(status)")
            } catch K9OGateError.regionUnavailable(let s, _, _) {
                XCTAssertEqual(s, 503)
                XCTAssertEqual(status, 503)
            } catch K9OGateError.rateLimited(let s, _, _) {
                XCTAssertEqual(s, 429)
                XCTAssertEqual(status, 429)
            }
            XCTAssertEqual(seen.requests.count, 1)
        }
    }

    func testRaisesAnyOtherDoorFailureAsTheUsualErrorWithNoRetry() async throws {
        let seen = Seen()
        StubURLProtocol.register(method: "POST", pathSuffix: "locate") { req in
            seen.add(req)
            return (500, errorEnvelope(code: "K9O_INTERNAL_ERROR"))
        }
        credential(seen)
        do {
            _ = try await gate().signIn(email: "a@b.co", password: "pw")
            XCTFail("expected a thrown error")
        } catch K9OGateError.unknown(let status, _, _) {
            XCTAssertEqual(status, 500)
        }
        XCTAssertEqual(seen.requests.count, 1)
    }

    func testUsesTheBaseWhenTheDoorAnswers404() async throws {
        let seen = Seen()
        StubURLProtocol.register(method: "POST", pathSuffix: "locate") { req in
            seen.add(req)
            return (404, errorEnvelope(code: "K9O_NOT_FOUND"))
        }
        credential(seen)
        _ = try await gate().signIn(email: "a@b.co", password: "pw")
        XCTAssertEqual(seen.urls, [
            "https://acme.api-de01.k9o.io/@portal/gate/locate",
            "https://acme.api-de01.k9o.io/@portal/gate/signin",
        ])
    }

    func testUsesTheBaseWhenTheDoorAnswers404WithNoBody() async throws {
        let seen = Seen()
        StubURLProtocol.register(method: "POST", pathSuffix: "locate") { req in
            seen.add(req)
            return (404, nil)
        }
        credential(seen)
        _ = try await gate().signIn(email: "a@b.co", password: "pw")
        XCTAssertEqual(seen.urls[1], "https://acme.api-de01.k9o.io/@portal/gate/signin")
    }

    func testStillRaisesWhenTheDoorAnswers404AndThenSignInAnswers404() async throws {
        let seen = Seen()
        StubURLProtocol.register(method: "POST", pathSuffix: "locate") { req in
            seen.add(req)
            return (404, errorEnvelope(code: "K9O_NOT_FOUND"))
        }
        StubURLProtocol.register(method: "POST", pathSuffix: "signin") { req in
            seen.add(req)
            return (404, errorEnvelope(code: "K9O_NOT_FOUND"))
        }
        do {
            _ = try await gate().signIn(email: "a@b.co", password: "pw")
            XCTFail("expected a thrown error")
        } catch K9OGateError.unknown(let status, _, _) {
            XCTAssertEqual(status, 404)
        }
        XCTAssertEqual(seen.urls, [
            "https://acme.api-de01.k9o.io/@portal/gate/locate",
            "https://acme.api-de01.k9o.io/@portal/gate/signin",
        ])
    }

    func testDoesNotCacheTheLocatedOriginTheNextSignInAsksAgain() async throws {
        let seen = Seen()
        StubURLProtocol.register(method: "POST", pathSuffix: "locate") { req in
            seen.add(req)
            let region = seen.urls.filter { $0.hasSuffix("/gate/locate") }.count == 1 ? "us01" : "fr01"
            return (200, jsonData(["data": ["region": region, "origin": "https://acme.api-\(region).k9o.io"], "meta": [:]]))
        }
        credential(seen)
        let g = gate()
        _ = try await g.signIn(email: "a@b.co", password: "pw")
        _ = try await g.signIn(email: "a@b.co", password: "pw")
        XCTAssertEqual(seen.urls.filter { $0.hasSuffix("/gate/locate") }.count, 2)
        XCTAssertEqual(seen.urls.filter { $0.hasSuffix("/signin") }, [
            "https://acme.api-us01.k9o.io/@portal/gate/signin",
            "https://acme.api-fr01.k9o.io/@portal/gate/signin",
        ])
    }

    func testSendsRefreshAndSignOutToTheOriginThatIssuedTheSession() async throws {
        let seen = Seen()
        door(seen, region: "us01", origin: "https://acme.api-us01.k9o.io")
        credential(seen)
        let g = gate()
        _ = try await g.signIn(email: "a@b.co", password: "pw")
        _ = try await g.refreshToken(refreshToken: "rt_MockRefreshToken0001")
        // The refresh answered the next token; the session's origin follows it.
        _ = try await g.signOut(refreshToken: "rt_NextToken0002")
        XCTAssertTrue(seen.urls.contains("https://acme.api-us01.k9o.io/@portal/gate/refresh"))
        XCTAssertTrue(seen.urls.contains("https://acme.api-us01.k9o.io/@portal/gate/signout"))
        _ = try await g.refreshToken(refreshToken: "rt_NextToken0002")
        XCTAssertEqual(seen.urls.last, "https://acme.api-de01.k9o.io/@portal/gate/refresh")
    }

    func testKeepsAtMost64SessionHintsDroppingTheOldest() {
        let origin = URL(string: "https://acme.api-us01.k9o.io")!
        let hints = SessionOrigins()
        for i in 0..<65 { hints.remember("cap-\(i)", origin) }
        XCTAssertNil(hints.hint("cap-0"))
        XCTAssertEqual(hints.hint("cap-64"), origin)
        XCTAssertEqual(hints.hint("cap-1"), origin)
    }
}
