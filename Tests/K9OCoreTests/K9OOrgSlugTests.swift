import XCTest
@testable import K9OCore

final class K9OOrgSlugTests: XCTestCase {
    private func resolve(_ base: String?, _ slug: String?) throws -> String {
        try k9oResolveBaseURL(base.map { URL(string: $0)! }, orgSlug: slug).absoluteString
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
                    XCTAssertEqual((e as? K9OError)?.code, "K9O_INVALID_FIELD_VALUE")
                    XCTAssertEqual((e as? K9OError)?.context, .object(["field": .string("orgSlug"), "slug": .string(bad)]))
                }
            }
        }
        XCTAssertNoThrow(try resolve(nil, String(repeating: "a", count: 63)))
        // A slug that would not be used is not validated.
        XCTAssertNoThrow(try resolve("https://acme.api.k9o.io", "Bad-"))
    }

    func testNeitherThrowsInvalidBaseUrl() {
        for slug in [nil, ""] {
            XCTAssertThrowsError(try resolve(nil, slug)) { e in
                XCTAssertEqual((e as? K9OError)?.code, "K9O_INVALID_BASE_URL")
                XCTAssertEqual((e as? K9OError)?.context, .object(["field": .string("baseUrl")]))
            }
        }
    }

    func testRequestGoesToComposedHost() async throws {
        let rec = Recorder()
        let c = try K9OCoreClient(orgSlug: "acme", projectSlug: "p", accessToken: "tok", transport: okTransport(rec, json: envelope([
                                      "modelId": "m", "content": "c", "finishReason": "stop",
                                      "usage": ["promptTokens": 1, "completionTokens": 1, "totalTokens": 2],
                                      "usageType": "ai.generate"])),
                                  probeTransport: { req in
                                      (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
                                  })
        _ = try await c.ai.generate("hi")
        XCTAssertEqual(rec.last.url?.host, "acme.api.k9o.io")
    }
}
