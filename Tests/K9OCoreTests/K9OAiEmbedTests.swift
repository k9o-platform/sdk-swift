import XCTest
@testable import K9OCore

private final class Capture: @unchecked Sendable {
    var requests: [URLRequest] = []
    var bodies: [Data] = []
}

private func stub(
    _ cap: Capture, status: Int = 200, body: [String: Any]? = nil, raw: Data? = nil, fail: Error? = nil
) -> K9OTransport {
    return { req in
        cap.requests.append(req)
        cap.bodies.append(req.httpBody ?? Data())
        if let fail { throw fail }
        let data = raw ?? (try! JSONSerialization.data(withJSONObject: body ?? [
            "data": ["embeddings": [[0.1, 0.2]], "model": "nomic-embed-text-v1.5", "dimensions": 2],
            "meta": [String: Any](),
        ]))
        let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        return (data, resp)
    }
}

private func client(_ t: @escaping K9OTransport, slug: String? = "member-portal") -> K9OCoreClient {
    K9OCoreClient(baseURL: URL(string: "https://acme.api-de01.k9o.io")!, projectSlug: slug,
                  accessToken: "tok_abc", transport: t)
}

private func json(_ d: Data) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: d) as! [String: Any]
}

final class K9OAiEmbedTests: XCTestCase {
    func testPostsToEmbeddingsWithBearerAndReturnsVectors() async throws {
        let cap = Capture()
        let r = try await client(stub(cap)).ai.embed(input: .one("hello"))
        XCTAssertEqual(cap.requests.count, 1)
        XCTAssertEqual(cap.requests[0].httpMethod, "POST")
        XCTAssertEqual(cap.requests[0].url?.absoluteString,
                       "https://acme.api-de01.k9o.io/@member-portal/ai/embeddings")
        XCTAssertEqual(cap.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tok_abc")
        XCTAssertEqual(r.data.embeddings, [[0.1, 0.2]])
        XCTAssertEqual(r.data.dimensions, 2)
        XCTAssertTrue(r.meta.isEmpty)
    }

    func testStringInputStaysAString() async throws {
        let cap = Capture()
        _ = try await client(stub(cap)).ai.embed(input: .one("hello"))
        let b = json(cap.bodies[0])
        XCTAssertEqual(b["input"] as? String, "hello")
        XCTAssertEqual(b.count, 1)
    }

    func testListInputWithModelSentAsGiven() async throws {
        let cap = Capture()
        _ = try await client(stub(cap)).ai.embed(
            model: "nomic-embed-text-v1.5", input: .many(["search_document: a", "search_document: b"]))
        let b = json(cap.bodies[0])
        XCTAssertEqual(b["model"] as? String, "nomic-embed-text-v1.5")
        XCTAssertEqual(b["input"] as? [String], ["search_document: a", "search_document: b"])
    }

    func testModelOmittedWhenNotGiven() async throws {
        let cap = Capture()
        _ = try await client(stub(cap)).ai.embed(input: .many(["x"]))
        XCTAssertNil(json(cap.bodies[0])["model"])
    }

    func testMissingSlugRefusedWithoutRequest() async {
        let cap = Capture()
        do {
            _ = try await client(stub(cap), slug: nil).ai.embed(input: .one("x"))
            XCTFail("expected throw")
        } catch let e as K9OError {
            XCTAssertEqual(e.code, "K9O_MISSING_PROJECT_CONTEXT")
        } catch { XCTFail("wrong error \(error)") }
        XCTAssertEqual(cap.requests.count, 0)
    }

    func testFlat4xxBodySurfacesAsKErrorWithoutInput() async {
        let cap = Capture()
        let secret = "the-secret-document-body"
        let body: [String: Any] = [
            "code": "K9O_MODEL_NOT_DECLARED",
            "message": "model is not a declared embedding model",
            "context": ["declared": ["nomic-embed-text-v1.5"]],
            "recommendation": NSNull(),
        ]
        do {
            _ = try await client(stub(cap, status: 400, body: body)).ai.embed(model: "other", input: .one(secret))
            XCTFail("expected throw")
        } catch let e as K9OError {
            XCTAssertEqual(e.code, "K9O_MODEL_NOT_DECLARED")
            XCTAssertEqual(e.status, 400)
            XCTAssertNil(e.recommendation)
            XCTAssertEqual(e.context, .object(["declared": .array([.string("nomic-embed-text-v1.5")])]))
            XCTAssertFalse("\(e)".contains(secret))
            XCTAssertFalse(e.description.contains(secret))
            XCTAssertFalse((e.errorDescription ?? "").contains(secret))
        } catch { XCTFail("wrong error \(error)") }
    }

    func testNetworkFailureMapsToUpstreamUnavailable() async {
        let cap = Capture()
        do {
            _ = try await client(stub(cap, fail: URLError(.notConnectedToInternet))).ai.embed(input: .one("x"))
            XCTFail("expected throw")
        } catch let e as K9OError {
            XCTAssertEqual(e.code, "K9O_UPSTREAM_UNAVAILABLE")
        } catch { XCTFail("wrong error \(error)") }
    }

    func testNonJSONErrorBodyMapsToInternalError() async {
        let cap = Capture()
        do {
            _ = try await client(stub(cap, status: 502, raw: Data("<html>bad gateway</html>".utf8))).ai.embed(input: .one("x"))
            XCTFail("expected throw")
        } catch let e as K9OError {
            XCTAssertEqual(e.code, "K9O_INTERNAL_ERROR")
            XCTAssertEqual(e.status, 502)
        } catch { XCTFail("wrong error \(error)") }
    }
}

final class K9ORecommendationDecodeTests: XCTestCase {
    private func err(_ status: Int, _ rec: Any?) async -> K9OError? {
        var body: [String: Any] = ["code": "K9O_X", "message": "msg", "context": ["x": 1]]
        if let rec { body["recommendation"] = rec } else { body["recommendation"] = NSNull() }
        let cap = Capture()
        do { _ = try await client(stub(cap, status: status, body: body)).ai.embed(input: .one("a")) } catch { return error as? K9OError }
        return nil
    }

    private func check(_ status: Int, _ rec: Any?, _ text: String?, _ wait: Double?, line: UInt = #line) async {
        let e = await err(status, rec)
        XCTAssertEqual(e?.code, "K9O_X", line: line)
        XCTAssertEqual(e?.message, "msg", line: line)
        XCTAssertEqual(e?.status, status, line: line)
        XCTAssertEqual(e?.context, .object(["x": .number(1)]), line: line)
        XCTAssertEqual(e?.recommendation, text, line: line)
        XCTAssertEqual(e?.retryAfterSec, wait, line: line)
    }

    func testObjectWithAction() async { await check(403, ["action": "Open Billing"], "Open Billing", nil) }
    func testObjectWithRetryAfterAndNote() async { await check(429, ["retryAfterSec": 30, "note": "retry"], "retry", 30) }
    func testNull() async { await check(429, nil, nil, nil) }
    func testString() async { await check(400, "do this", "do this", nil) }
    func testNumber() async { await check(400, 5, nil, nil) }
    func testArray() async { await check(400, ["a", "b"], nil, nil) }
    func testNegativeRetryAfterIgnored() async { await check(429, ["retryAfterSec": -1], nil, nil) }
}
