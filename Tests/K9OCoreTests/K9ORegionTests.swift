import XCTest
@testable import K9OCore

private final class Log: @unchecked Sendable {
    var requests: [URLRequest] = []
}

private func transport(_ log: Log, location: String? = "https://acme.api-staging-de01.k9o.io/", probeStatus: Int = 308)
    -> K9OTransport {
    return { req in
        log.requests.append(req)
        if req.httpMethod == "HEAD" {
            var h: [String: String] = [:]
            if let location { h["Location"] = location }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: probeStatus, httpVersion: "HTTP/1.1", headerFields: h)!)
        }
        let data = try! JSONSerialization.data(withJSONObject: [
            "data": ["modelId": "m", "content": "c", "finishReason": "stop",
                      "usage": ["promptTokens": 1, "completionTokens": 1, "totalTokens": 2], "usageType": "ai.generate"],
            "meta": [String: Any](),
        ])
        return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private func client(_ base: String, _ t: @escaping K9OTransport) -> K9OCoreClient {
    K9OCoreClient(baseURL: URL(string: base)!, projectSlug: "p", accessToken: "tok_abc", transport: t)
}

final class K9ORegionTests: XCTestCase {
    func testShortAddressProbesCredentialFreeThenCallsRegionalHostAndCaches() async throws {
        let log = Log()
        let c = client("https://acme.api-staging.k9o.io", transport(log))
        _ = try await c.ai.generate("hi")
        _ = try await c.ai.generate("again")
        XCTAssertEqual(log.requests.count, 3, "one probe, two calls")
        let probe = log.requests[0]
        XCTAssertEqual(probe.httpMethod, "HEAD")
        XCTAssertEqual(probe.url?.absoluteString, "https://acme.api-staging.k9o.io/")
        XCTAssertNil(probe.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(probe.httpBody)
        for r in log.requests.dropFirst() {
            XCTAssertEqual(r.url?.host, "acme.api-staging-de01.k9o.io")
            XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer tok_abc")
        }
    }

    func testAlreadyRegionalAddressIsNotProbed() async throws {
        let log = Log()
        _ = try await client("https://acme.api-staging-de01.k9o.io", transport(log)).ai.generate("hi")
        XCTAssertEqual(log.requests.count, 1)
        XCTAssertEqual(log.requests[0].httpMethod, "POST")
        XCTAssertEqual(log.requests[0].url?.host, "acme.api-staging-de01.k9o.io")
    }

    func testLocalhostIsNotProbed() async throws {
        let log = Log()
        _ = try await client("http://localhost:8080", transport(log)).ai.generate("hi")
        XCTAssertEqual(log.requests.map { $0.httpMethod }, ["POST"])
    }

    func testForeignLocationIsIgnoredAndConfiguredHostStays() async throws {
        for loc in ["https://evil.example.com/", "https://other.api-staging-de01.k9o.io/",
                    "http://acme.api-staging-de01.k9o.io/", "https://acme.api-staging-de01.k9o.io:8443/",
                    "https://acme.api-de01.k9o.io/", "https://acme.api-staging-de01.evil.io/"] {
            let log = Log()
            _ = try await client("https://acme.api-staging.k9o.io", transport(log, location: loc)).ai.generate("hi")
            XCTAssertEqual(log.requests.last?.url?.host, "acme.api-staging.k9o.io", loc)
        }
    }

    func testNonRedirectProbeKeepsConfiguredHost() async throws {
        let log = Log()
        _ = try await client("https://acme.api.k9o.io", transport(log, probeStatus: 200)).ai.generate("hi")
        XCTAssertEqual(log.requests.last?.url?.host, "acme.api.k9o.io")
    }

    func testProbeFailureIsNotCached() async throws {
        let log = Log()
        let ok = transport(log)
        let failFirst = FailOnce()
        let t: K9OTransport = { req in
            if req.httpMethod == "HEAD", failFirst.take() { throw URLError(.notConnectedToInternet) }
            return try await ok(req)
        }
        let c = client("https://acme.api-staging.k9o.io", t)
        _ = try await c.ai.generate("a")
        XCTAssertEqual(log.requests.last?.url?.host, "acme.api-staging.k9o.io")
        _ = try await c.ai.generate("b")
        XCTAssertEqual(log.requests.last?.url?.host, "acme.api-staging-de01.k9o.io")
    }

    func testUsageTypeOnTheWireAndOmittedWhenNil() async throws {
        let log = Log()
        let c = client("https://acme.api-staging-de01.k9o.io", transport(log))
        _ = try await c.ai.generate("hi", usageType: "support.summary")
        _ = try await c.ai.generate("hi")
        let b1 = try JSONSerialization.jsonObject(with: log.requests[0].httpBody!) as! [String: Any]
        let b2 = try JSONSerialization.jsonObject(with: log.requests[1].httpBody!) as! [String: Any]
        XCTAssertEqual(b1["usageType"] as? String, "support.summary")
        XCTAssertNil(b2["usageType"])
    }
}

private final class FailOnce: @unchecked Sendable {
    private var done = false
    func take() -> Bool { if done { return false }; done = true; return true }
}
