import Foundation

/// URLProtocol stub for intercepting gateway requests in tests.
/// Register a handler keyed on HTTP method + path suffix before each test.
final class StubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (statusCode: Int, body: Data?)

    // Thread-safe stub registry keyed by "<METHOD> <path-suffix>", e.g. "POST signin"
    private static var handlers: [String: Handler] = [:]
    // Extra response headers per key, sent with that key's answer (the Content-Type header is always sent).
    private static var extraHeaders: [String: [String: String]] = [:]
    private static let lock = NSLock()

    static func register(
        method: String, pathSuffix: String, headers: [String: String] = [:], handler: @escaping Handler
    ) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(method.uppercased()) \(pathSuffix)"
        handlers[key] = handler
        extraHeaders[key] = headers
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handlers = [:]
        extraHeaders = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        let method = request.httpMethod?.uppercased() ?? "GET"

        // Match on last path component (the "signin" / "refresh" / etc. suffix)
        let suffix = url.components(separatedBy: "/").last ?? ""
        let key = "\(method) \(suffix)"

        var handler: Handler?
        var headers: [String: String] = [:]
        StubURLProtocol.lock.lock()
        handler = StubURLProtocol.handlers[key]
        headers = StubURLProtocol.extraHeaders[key] ?? [:]
        StubURLProtocol.lock.unlock()
        // Sign-in asks the locate door first. Tests about the call after it get a door that answers "stay on the base";
        // LocateTests registers its own.
        if handler == nil && key == "POST locate" {
            handler = { _ in (200, jsonData(["data": ["region": "de01", "origin": NSNull()], "meta": [:]])) }
        }

        if let h = handler {
            // URLSession moves the request body to `httpBodyStream`, leaving
            // `httpBody` nil inside the protocol — rehydrate it so handlers can
            // inspect the sent body (e.g. assert the refreshToken field).
            var req = request
            if req.httpBody == nil, let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                let bufSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
                while stream.hasBytesAvailable {
                    let n = stream.read(buffer, maxLength: bufSize)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                }
                buffer.deallocate()
                stream.close()
                req.httpBody = data
            }
            let (statusCode, body) = h(req)
            var fields = ["Content-Type": "application/json"]
            fields.merge(headers) { _, extra in extra }
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: fields
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            if let data = body {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let error = URLError(.unsupportedURL)
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - JSON fixture helpers

func jsonData(_ dict: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: dict)
}

let mockUser: [String: Any] = [
    "id": "eu_TestUserABC123",
    "email": "user@example.com",
    "status": "active",
    "createdAt": "2026-01-01T00:00:00Z",
    "updatedAt": NSNull(),
    "lastSigninAt": NSNull(),
    "roles": ["PROJECT_END_USER"],
    "groups": [],
]

let mockSession: [String: Any] = [
    "accessToken": "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJldV9UZXN0VXNlckFCQzEyMyIsImV4cCI6OTk5OTk5OTk5OSwiaWF0IjoxNzAwMDAwMDAwLCJpc3MiOiJodHRwczovL2FwaS5rOW8uaW8iLCJleHQucGFydG5lcnMiOnsicGFydG5lcl9yb2xlIjoiZXh0ZW5zaW9uX29yZ19hZG1pbiJ9fQ.sig",
    "refreshToken": "rt_MockRefreshToken0001",
    "expiresAt": "2099-01-01T00:00:00Z",
]

/// The real refresh response: `{ accessToken, refreshToken, expiresAt }`. The refresh token is the next one.
func refreshEnvelope() -> Data {
    jsonData([
        "data": [
            "accessToken": mockSession["accessToken"]!,
            "refreshToken": "rt_NextToken0002",
            "expiresAt": "2099-01-01T00:00:00Z",
        ],
        "meta": [:],
    ])
}

/// The body of a request, read as `{ refreshToken }`.
func sentToken(_ req: URLRequest) -> String {
    let body = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data())) as? [String: Any]
    return body?["refreshToken"] as? String ?? ""
}

/// A list a stub handler can add to from the URLSession's threads.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// The gateway's answer when a session has ended: `K9O_SESSION_EXPIRED` with the reason in `context`.
func sessionExpiredEnvelope(reason: String) -> Data {
    jsonData(["code": "K9O_SESSION_EXPIRED", "message": "x", "context": ["reason": reason], "recommendation": NSNull()])
}

func authResultEnvelope() -> Data {
    jsonData(["data": ["user": mockUser, "session": mockSession], "meta": [:]])
}

// Matches the real gateway error body: a KError at the ROOT, with
// platform-namespaced `K9O_*` codes — NOT a `{ "error": { … } }` wrapper.
func errorEnvelope(code: String, message: String = "Error") -> Data {
    jsonData(["code": code, "message": message])
}
