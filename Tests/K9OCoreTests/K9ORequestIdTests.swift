import XCTest
@testable import K9OCore

final class K9ORequestIdTests: XCTestCase {
    private func fail(headers: [String: String], body: [String: Any]) async -> K9OError? {
        let t: K9OTransport = { req in
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
        do { _ = try await makeClient(t).sendRaw(method: "GET", path: "/x"); return nil } catch { return error as? K9OError }
    }
    private let nf: [String: Any] = ["code": "K9O_NOT_FOUND", "message": "no"]

    func testHeaderFillsRequestId() async {
        let e = await fail(headers: ["x-k9o-request-id": "req_abc"], body: nf)
        XCTAssertEqual(e?.requestId, "req_abc")
    }
    func testBodyWins() async {
        let e = await fail(headers: ["x-k9o-request-id": "req_hdr"], body: nf.merging(["requestId": "req_body"]) { $1 })
        XCTAssertEqual(e?.requestId, "req_body")
    }
    func testNoneIsNil() async {
        let e = await fail(headers: [:], body: nf)
        XCTAssertNotNil(e)
        XCTAssertNil(e?.requestId)
    }
    func testHeaderCaseInsensitive() async {
        let e = await fail(headers: ["X-K9O-Request-Id": "req_abc"], body: nf)
        XCTAssertEqual(e?.requestId, "req_abc")
    }
}
