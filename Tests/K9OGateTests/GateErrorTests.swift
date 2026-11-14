import XCTest
@testable import K9OGate

final class GateErrorTests: XCTestCase {
    private var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() async throws {
        StubURLProtocol.reset()
        try await super.tearDown()
    }

    private func client(_ errors: K9OGateErrorMode = .full) -> GateClient {
        GateClient(
            orgBaseURL: URL(string: "https://acme.api.k9o.io")!,
            projectSlug: "test-project",
            tokenStore: nil,
            urlSession: session,
            errors: errors
        )
    }

    /// Signs in against a stubbed `signin` answer and returns the error it threw.
    private func signInError(
        status: Int, body: Data, errors: K9OGateErrorMode = .full, headers: [String: String] = [:]
    ) async -> K9OGateError? {
        StubURLProtocol.register(method: "POST", pathSuffix: "signin", headers: headers) { _ in (status, body) }
        do {
            _ = try await client(errors).signIn(email: "user@example.com", password: "pass")
            XCTFail("Expected sign-in to throw")
            return nil
        } catch let error as K9OGateError {
            return error
        } catch {
            XCTFail("Expected K9OGateError, got \(error)")
            return nil
        }
    }

    private var magicLinkBody: Data {
        jsonData([
            "code": "K9O_MAGIC_LINK_REDIRECT_NOT_CONFIGURED",
            "message": "x",
            "recommendation": ["action": "Register a default redirect"],
        ])
    }

    // (a) Default mode keeps an unknown wire code, its recommendation and the status.
    func testUnknownCodeKeepsWireCodeRecommendationAndStatus() async throws {
        let error = await signInError(status: 503, body: magicLinkBody)
        XCTAssertEqual(error?.code, "K9O_MAGIC_LINK_REDIRECT_NOT_CONFIGURED")
        XCTAssertEqual(error?.statusCode, 503)
        XCTAssertEqual(error?.recommendation, "Register a default redirect")
        XCTAssertEqual(error?.publicMessage, "Something went wrong. Try again later.")
        XCTAssertNil(error?.retryAfterSec)
        if case .unknown(let status, let body, _)? = error {
            XCTAssertEqual(status, 503)
            XCTAssertNotNil(body)
        } else {
            XCTFail("Expected .unknown, got \(String(describing: error))")
        }
    }

    // (b) Redacted mode drops the unknown code, body, recommendation and gateway text; status and publicMessage stay.
    func testRedactedModeDropsUnknownCodeAndGatewayText() async throws {
        let error = await signInError(status: 503, body: magicLinkBody, errors: .redacted)
        if case .unknown(let status, let body, _)? = error {
            XCTAssertEqual(status, 503)
            XCTAssertNil(body)
        } else {
            XCTFail("Expected .unknown, got \(String(describing: error))")
        }
        XCTAssertNil(error?.code)
        XCTAssertNil(error?.recommendation)
        XCTAssertNil(error?.retryAfterSec)
        XCTAssertEqual(error?.statusCode, 503)
        XCTAssertEqual(error?.publicMessage, "Something went wrong. Try again later.")
        XCTAssertEqual(error?.errorDescription, "Unexpected error (HTTP 503): <no body>")
    }

    // (c) A known code keeps its code and its typed case in both modes.
    func testKnownCodeBehavesTheSameInBothModes() async throws {
        for mode in [K9OGateErrorMode.full, .redacted] {
            let error = await signInError(
                status: 401,
                body: jsonData(["code": "K9O_INVALID_CREDENTIALS", "message": "no match"]),
                errors: mode
            )
            if case .invalidCredentials? = error {
                // pass
            } else {
                XCTFail("Expected .invalidCredentials in \(mode), got \(String(describing: error))")
            }
            XCTAssertEqual(error?.code, "K9O_INVALID_CREDENTIALS")
            XCTAssertEqual(error?.statusCode, 401)
            XCTAssertEqual(error?.publicMessage, "You are not signed in or not allowed to do this.")
        }
    }

    // (d) A 429 keeps its retry wait in redacted mode.
    func testRateLimitKeepsRetryWaitWhenRedacted() async throws {
        let body = jsonData([
            "code": "K9O_RATE_LIMITED",
            "message": "slow down",
            "recommendation": ["retryAfterSec": 30, "note": "Wait before you try again"],
        ])
        let full = await signInError(status: 429, body: body)
        XCTAssertEqual(full?.recommendation, "Wait before you try again")
        XCTAssertEqual(full?.retryAfterSec, 30)

        let redacted = await signInError(status: 429, body: body, errors: .redacted)
        if case .rateLimited(let status, _, _)? = redacted {
            XCTAssertEqual(status, 429)
        } else {
            XCTFail("Expected .rateLimited, got \(String(describing: redacted))")
        }
        XCTAssertEqual(redacted?.code, "K9O_RATE_LIMITED")
        XCTAssertEqual(redacted?.retryAfterSec, 30)
        XCTAssertNil(redacted?.recommendation)
        XCTAssertEqual(redacted?.publicMessage, "Too many attempts. Try again later.")
    }

    // A locate answer of 404 still means "stay on the base address" in redacted mode.
    func testLocateNotFoundStillUsesBaseInRedactedMode() async throws {
        StubURLProtocol.register(method: "POST", pathSuffix: "locate") { _ in
            (404, jsonData(["code": "K9O_NOT_FOUND", "message": "no locate"]))
        }
        StubURLProtocol.register(method: "POST", pathSuffix: "signin") { _ in (200, authResultEnvelope()) }
        let result = try await client(.redacted).signIn(email: "user@example.com", password: "pass")
        XCTAssertEqual(result.user.id, "eu_TestUserABC123")
    }

    // (e) Only the two modes exist; any other string is not a mode.
    func testErrorModeRawValuesAreClosed() {
        XCTAssertEqual(K9OGateErrorMode(rawValue: "full"), .full)
        XCTAssertEqual(K9OGateErrorMode(rawValue: "redacted"), .redacted)
        XCTAssertNil(K9OGateErrorMode(rawValue: "bogus"))
        XCTAssertNil(K9OGateErrorMode(rawValue: "Redacted"))
    }

    // publicMessage is chosen by status class only.
    func testPublicMessageByStatusClass() {
        let auth = "You are not signed in or not allowed to do this."
        XCTAssertEqual(K9OGateError.from(statusCode: 401, data: Data()).publicMessage, auth)
        XCTAssertEqual(K9OGateError.from(statusCode: 403, data: Data()).publicMessage, auth)
        XCTAssertEqual(K9OGateError.from(statusCode: 404, data: jsonData(["code": "K9O_NOPE"])).publicMessage, "Not found.")
        XCTAssertEqual(
            K9OGateError.from(statusCode: 429, data: jsonData(["code": "K9O_NOPE"])).publicMessage,
            "Too many attempts. Try again later."
        )
        XCTAssertEqual(
            K9OGateError.from(statusCode: 502, data: Data()).publicMessage,
            "Something went wrong. Try again later."
        )
        XCTAssertEqual(
            K9OGateError.from(statusCode: 400, data: jsonData(["code": "K9O_INVALID_REQUEST_SHAPE"])).publicMessage,
            "The request could not be completed."
        )
        XCTAssertEqual(K9OGateError.network(URLError(.timedOut)).publicMessage, "Could not reach the service.")
        XCTAssertEqual(K9OGateError.decoding(URLError(.badURL)).publicMessage, "The request could not be completed.")
    }

    func testBodylessUnknownHasNoCodeOrRecommendation() {
        let error = K9OGateError.from(statusCode: 500, data: Data("oops".utf8))
        XCTAssertNil(error.code)
        XCTAssertNil(error.recommendation)
        XCTAssertNil(error.retryAfterSec)
        XCTAssertEqual(error.statusCode, 500)
    }

    // (f) The x-k9o-request-id header is kept as requestId on an unknown code, in both modes.
    func testRequestIdFromHeaderOnUnknownCodeInBothModes() async throws {
        for mode in [K9OGateErrorMode.full, .redacted] {
            let error = await signInError(
                status: 503, body: magicLinkBody, errors: mode, headers: ["x-k9o-request-id": "req_abc"]
            )
            XCTAssertEqual(error?.requestId, "req_abc", "requestId in \(mode)")
            XCTAssertEqual(error?.statusCode, 503)
        }
    }

    // (g) A typed case keeps the header value as its requestId in both modes.
    func testRequestIdFromHeaderOnTypedCaseInBothModes() async throws {
        for mode in [K9OGateErrorMode.full, .redacted] {
            let error = await signInError(
                status: 401,
                body: jsonData(["code": "K9O_INVALID_CREDENTIALS", "message": "no match"]),
                errors: mode,
                headers: ["x-k9o-request-id": "req_abc"]
            )
            if case .invalidCredentials(let id)? = error {
                XCTAssertEqual(id, "req_abc", "requestId in \(mode)")
            } else {
                XCTFail("Expected .invalidCredentials in \(mode), got \(String(describing: error))")
            }
            XCTAssertEqual(error?.requestId, "req_abc")
        }
    }

    // (h) A response without the header has no requestId, for an unknown code or a typed case.
    func testResponseWithoutHeaderHasNilRequestId() async throws {
        let unknown = await signInError(status: 503, body: magicLinkBody)
        XCTAssertNil(unknown?.requestId)
        let typed = await signInError(
            status: 401, body: jsonData(["code": "K9O_INVALID_CREDENTIALS", "message": "no match"])
        )
        XCTAssertNil(typed?.requestId)
    }

    func testRecommendationObjectWithoutActionOrNoteIsNil() {
        let error = K9OGateError.from(
            statusCode: 503,
            data: jsonData(["code": "K9O_X", "message": "x", "recommendation": ["retryAfterSec": 5]])
        )
        XCTAssertNil(error.recommendation)
        XCTAssertEqual(error.retryAfterSec, 5)
    }
}
