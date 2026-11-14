import XCTest
@testable import K9OGate

final class OrgSlugTests: XCTestCase {
    private func resolve(_ base: String?, _ slug: String?) throws -> String {
        try gateResolveBaseURL(base.map { URL(string: $0)! }, orgSlug: slug).absoluteString
    }

    func testFullOrgUrlIsUnchangedWithAndWithoutSlug() throws {
        XCTAssertEqual(try resolve("https://acme.api.k9o.io", nil), "https://acme.api.k9o.io")
        XCTAssertEqual(try resolve("https://acme.api.k9o.io", "other"), "https://acme.api.k9o.io")
        XCTAssertEqual(try resolve("https://acme.api-de01.k9o.io", "other"), "https://acme.api-de01.k9o.io")
    }

    func testCustomDomainLocalhostAndIpAreUnchanged() throws {
        for base in ["https://auth.example.com", "http://localhost:3000", "http://127.0.0.1:8080"] {
            XCTAssertEqual(try resolve(base, nil), base)
            XCTAssertEqual(try resolve(base, "acme"), base)
        }
    }

    func testPlatformHostWithSlugComposesOrgHost() throws {
        XCTAssertEqual(try resolve("https://api.k9o.io", "acme"), "https://acme.api.k9o.io")
        XCTAssertEqual(try resolve("http://api.k9o.io:8443", "acme"), "http://acme.api.k9o.io:8443")
        XCTAssertEqual(try resolve("https://api-staging.example.org", "acme"), "https://acme.api-staging.example.org")
        XCTAssertEqual(try resolve("https://api-de01.k9o.io", "acme"), "https://api-de01.k9o.io")
        XCTAssertEqual(try resolve("https://api.k9o.io", nil), "https://api.k9o.io")
    }

    func testSlugOnlyUsesPlatformAddress() throws {
        XCTAssertEqual(try resolve(nil, "acme"), "https://acme.api.k9o.io")
    }

    func testBadSlugThrowsInvalidFieldValue() {
        for bad in ["Acme", "acme-", "a", String(repeating: "a", count: 64)] {
            for base in [nil, "https://api.k9o.io"] {
                XCTAssertThrowsError(try resolve(base, bad)) { e in
                    XCTAssertEqual((e as? K9OGateConfigError)?.code, "K9O_INVALID_FIELD_VALUE")
                    XCTAssertEqual((e as? K9OGateConfigError)?.context, ["field": "orgSlug", "slug": bad])
                    XCTAssertFalse((e as? K9OGateConfigError)?.message.isEmpty ?? true)
                }
            }
        }
        XCTAssertNoThrow(try resolve(nil, String(repeating: "a", count: 63)))
        XCTAssertNoThrow(try resolve("https://acme.api.k9o.io", "Bad-"))
    }

    func testNeitherThrowsInvalidBaseUrl() {
        for slug in [nil, ""] {
            XCTAssertThrowsError(try resolve(nil, slug)) { e in
                XCTAssertEqual(e as? K9OGateConfigError, .invalidBaseURL)
                XCTAssertEqual((e as? K9OGateConfigError)?.code, "K9O_INVALID_BASE_URL")
                XCTAssertEqual((e as? K9OGateConfigError)?.context, ["field": "baseUrl"])
                XCTAssertFalse((e as? K9OGateConfigError)?.message.isEmpty ?? true)
            }
        }
    }

    func testSignInGoesToComposedHost() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let seen = GateRegionTests.Probes()
        StubURLProtocol.register(method: "POST", pathSuffix: "signin") { req in
            seen.add(req)
            return (200, authResultEnvelope())
        }
        let gate = try GateClient(orgSlug: "acme", projectSlug: "p", tokenStore: nil, urlSession: session,
                                  probeTransport: { req in
                                      (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
                                  })
        _ = try await gate.signIn(email: "a@b.co", password: "p")
        XCTAssertEqual(seen.requests.first?.url?.absoluteString, "https://acme.api.k9o.io/@p/gate/signin")
    }
}
