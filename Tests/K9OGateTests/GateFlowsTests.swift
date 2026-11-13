import XCTest
@testable import K9OGate

final class GateFlowsTests: XCTestCase {
    var gate: GateClient!
    var session: URLSession!
    let base = "https://acme.api.example.test/@test-project/gate"

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
        gate = GateClient(
            orgBaseURL: URL(string: "https://acme.api.example.test")!,
            projectSlug: "test-project",
            tokenStore: nil,
            urlSession: session
        )
    }

    override func tearDown() async throws {
        StubURLProtocol.reset()
        try await super.tearDown()
    }

    private func body(_ req: URLRequest?) throws -> [String: Any] {
        try (JSONSerialization.jsonObject(with: req?.httpBody ?? Data()) as? [String: Any]) ?? [:]
    }

    private func envelope(_ data: [String: Any]) -> Data { jsonData(["data": data, "meta": [:]]) }

    // MARK: - passkeys

    func testRegisterBeginPostsWithTheBearerAndNoBody() async throws {
        var seen: URLRequest?
        StubURLProtocol.register(method: "POST", pathSuffix: "begin") { req in
            seen = req
            return (200, self.envelope(["challenge": "ch_1", "rp": ["name": "Acme"], "timeout": 60000]))
        }
        let options = try await gate.passkeys.register.begin(bearerToken: "at_user")
        XCTAssertEqual(seen?.httpMethod, "POST")
        XCTAssertEqual(seen?.url?.absoluteString, "\(base)/passkeys/register/begin")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer at_user")
        XCTAssertNil(seen?.httpBody)
        XCTAssertEqual(options.challenge, "ch_1")
        XCTAssertEqual(options.json["rp"], .object(["name": .string("Acme")]))
        XCTAssertEqual(options.json["timeout"], .number(60000))
    }

    func testRegisterFinishSendsTheCredentialAndLabel() async throws {
        var seen: URLRequest?
        StubURLProtocol.register(method: "POST", pathSuffix: "finish") { req in
            seen = req
            return (200, self.envelope(["passkey": ["id": "pk_1", "credentialId": "cred_1"]]))
        }
        let result = try await gate.passkeys.register.finish(
            response: ["id": .string("cred_1"), "response": .object(["attestationObject": .string("abc")])],
            label: "Laptop",
            bearerToken: "at_user"
        )
        XCTAssertEqual(seen?.url?.absoluteString, "\(base)/passkeys/register/finish")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer at_user")
        let sent = try body(seen)
        XCTAssertEqual(sent["label"] as? String, "Laptop")
        XCTAssertEqual((sent["response"] as? [String: Any])?["id"] as? String, "cred_1")
        XCTAssertEqual(result.passkey, K9OPasskey(id: "pk_1", credentialId: "cred_1"))
    }

    func testSignInBeginSendsNoCredentialAndTheEmail() async throws {
        var seen: URLRequest?
        StubURLProtocol.register(method: "POST", pathSuffix: "begin") { req in
            seen = req
            return (200, self.envelope(["challenge": "ch_2", "rpId": "example.test"]))
        }
        let options = try await gate.passkeys.signIn.begin(email: "user@example.test")
        XCTAssertEqual(seen?.url?.absoluteString, "\(base)/passkeys/signin/begin")
        XCTAssertNil(seen?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(try body(seen)["email"] as? String, "user@example.test")
        XCTAssertEqual(options.challenge, "ch_2")
    }

    func testSignInBeginWithoutAnEmailSendsAnEmptyObject() async throws {
        var seen: URLRequest?
        StubURLProtocol.register(method: "POST", pathSuffix: "begin") { req in
            seen = req
            return (200, self.envelope(["challenge": "ch_3"]))
        }
        _ = try await gate.passkeys.signIn.begin()
        XCTAssertTrue(try body(seen).isEmpty)
    }

    func testSignInFinishReturnsTheSession() async throws {
        var seen: URLRequest?
        StubURLProtocol.register(method: "POST", pathSuffix: "finish") { req in
            seen = req
            return (200, self.envelope(["session": mockSession]))
        }
        let result = try await gate.passkeys.signIn.finish(response: ["id": .string("cred_1"), "response": .object([:])])
        XCTAssertEqual(seen?.url?.absoluteString, "\(base)/passkeys/signin/finish")
        XCTAssertNil(seen?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(result.session.refreshToken, "rt_MockRefreshToken0001")
    }

    func testAnInvalidChallengeThrowsTheGatewayCodeWithStatus400() async throws {
        StubURLProtocol.register(method: "POST", pathSuffix: "finish") { _ in
            (400, jsonData(["code": "K9O_INVALID_FIELD_VALUE", "message": "challenge expired"]))
        }
        do {
            _ = try await gate.passkeys.signIn.finish(response: ["id": .string("x"), "response": .object([:])])
            XCTFail("expected a throw")
        } catch let error as K9OGateError {
            XCTAssertEqual(error.statusCode, 400)
            XCTAssertEqual(error.code, "K9O_INVALID_FIELD_VALUE")
        }
    }

    // MARK: - TOTP

    func testTotpEnrollSendsTheLabelWithTheBearer() async throws {
        var seen: URLRequest?
        StubURLProtocol.register(method: "POST", pathSuffix: "enroll") { req in
            seen = req
            return (200, self.envelope(["factor": ["id": "f_1", "secret": "JBSWY3DPEHPK3PXP", "uri": "otpauth://totp/Acme"]]))
        }
        let result = try await gate.mfa.totp.enroll(label: "Phone", bearerToken: "at_user")
        XCTAssertEqual(seen?.url?.absoluteString, "\(base)/mfa/totp/enroll")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer at_user")
        XCTAssertEqual(try body(seen)["label"] as? String, "Phone")
        XCTAssertEqual(result.factor, K9OTotpFactorSetup(id: "f_1", secret: "JBSWY3DPEHPK3PXP", uri: "otpauth://totp/Acme"))
    }

    func testTotpConfirmSendsFactorCodeAndCurrentCodeAndReadsTheSession() async throws {
        var seen: URLRequest?
        StubURLProtocol.register(method: "POST", pathSuffix: "confirm") { req in
            seen = req
            return (200, self.envelope(["factor": ["id": "f_1", "verifiedAt": "2026-11-13T00:00:00Z"], "session": mockSession]))
        }
        let result = try await gate.mfa.totp.confirm(factorId: "f_1", code: "123456", currentCode: "654321", bearerToken: "at_user")
        XCTAssertEqual(seen?.url?.absoluteString, "\(base)/mfa/totp/confirm")
        let sent = try body(seen)
        XCTAssertEqual(sent["factorId"] as? String, "f_1")
        XCTAssertEqual(sent["code"] as? String, "123456")
        XCTAssertEqual(sent["currentCode"] as? String, "654321")
        XCTAssertEqual(result.factor.verifiedAt, "2026-11-13T00:00:00Z")
        XCTAssertNotNil(result.session)
    }

    func testTotpConfirmWithAWrongCodeIsInvalidCredentials() async throws {
        StubURLProtocol.register(method: "POST", pathSuffix: "confirm") { _ in
            (401, jsonData(["code": "K9O_INVALID_CREDENTIALS", "message": "wrong code"]))
        }
        do {
            _ = try await gate.mfa.totp.confirm(factorId: "f_1", code: "000000", bearerToken: "at_user")
            XCTFail("expected a throw")
        } catch K9OGateError.invalidCredentials {
            // expected
        }
    }

    // MARK: - MFA methods

    func testMfaMethodsListReadsTheFactorsWithTheBearer() async throws {
        var seen: URLRequest?
        StubURLProtocol.register(method: "GET", pathSuffix: "methods") { req in
            seen = req
            return (200, self.envelope(["methods": [
                ["id": "f_1", "type": "totp", "label": "Phone", "verifiedAt": "2026-11-13T00:00:00Z", "createdAt": "2026-11-12T00:00:00Z"],
                ["id": "f_2", "type": "totp", "label": NSNull(), "verifiedAt": NSNull(), "createdAt": "2026-11-13T00:00:00Z"],
            ]]))
        }
        let result = try await gate.mfa.methods.list(bearerToken: "at_user")
        XCTAssertEqual(seen?.httpMethod, "GET")
        XCTAssertEqual(seen?.url?.absoluteString, "\(base)/mfa/methods")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer at_user")
        XCTAssertEqual(result.methods.count, 2)
        XCTAssertEqual(result.methods[0], K9OMfaMethod(id: "f_1", type: "totp", label: "Phone", verifiedAt: "2026-11-13T00:00:00Z", createdAt: "2026-11-12T00:00:00Z"))
        XCTAssertNil(result.methods[1].label)
        XCTAssertNil(result.methods[1].verifiedAt)
    }

    func testMfaMethodsListWithoutAValidTokenIsUnauthenticated() async throws {
        StubURLProtocol.register(method: "GET", pathSuffix: "methods") { _ in
            (401, jsonData(["code": "K9O_UNAUTHENTICATED", "message": "no"]))
        }
        do {
            _ = try await gate.mfa.methods.list(bearerToken: "bad")
            XCTFail("expected a throw")
        } catch K9OGateError.unauthenticated {
            // expected
        }
    }

    func testMfaMethodsDeleteSendsTheCodeAndTheBearer() async throws {
        var seen: URLRequest?
        StubURLProtocol.register(method: "DELETE", pathSuffix: "f_1") { req in
            seen = req
            return (200, self.envelope(["deleted": true]))
        }
        let result = try await gate.mfa.methods.delete(methodId: "f_1", code: "123456", bearerToken: "at_user")
        XCTAssertEqual(seen?.httpMethod, "DELETE")
        XCTAssertEqual(seen?.url?.absoluteString, "\(base)/mfa/methods/f_1")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer at_user")
        XCTAssertEqual(try body(seen)["code"] as? String, "123456")
        XCTAssertTrue(result.deleted)
    }

    func testMfaMethodsDeleteWithoutACodeSendsNoBody() async throws {
        var seen: URLRequest?
        StubURLProtocol.register(method: "DELETE", pathSuffix: "f_2") { req in
            seen = req
            return (200, self.envelope(["deleted": false]))
        }
        let result = try await gate.mfa.methods.delete(methodId: "f_2", bearerToken: "at_user")
        XCTAssertNil(seen?.httpBody)
        XCTAssertNil(seen?.httpBodyStream)
        XCTAssertFalse(result.deleted)
    }

    func testMfaMethodsDeleteOfAConfirmedAuthenticatorWithoutACodeThrowsMfaRequired() async throws {
        StubURLProtocol.register(method: "DELETE", pathSuffix: "f_1") { _ in
            (403, jsonData(["code": "K9O_MFA_REQUIRED", "message": "needs code"]))
        }
        do {
            _ = try await gate.mfa.methods.delete(methodId: "f_1", bearerToken: "at_user")
            XCTFail("expected a throw")
        } catch let error as K9OGateError {
            XCTAssertEqual(error.code, "K9O_MFA_REQUIRED")
        }
    }

    func testMfaMethodsDeleteWithAWrongCodeIsInvalidCredentials() async throws {
        StubURLProtocol.register(method: "DELETE", pathSuffix: "f_1") { _ in
            (401, jsonData(["code": "K9O_INVALID_CREDENTIALS", "message": "wrong code"]))
        }
        do {
            _ = try await gate.mfa.methods.delete(methodId: "f_1", code: "000000", bearerToken: "at_user")
            XCTFail("expected a throw")
        } catch K9OGateError.invalidCredentials {
            // expected
        }
    }

    // MARK: - password reset

    func testPasswordResetRequestAsksLocateFirstThenSendsNoCredential() async throws {
        var seen: URLRequest?
        StubURLProtocol.register(method: "POST", pathSuffix: "request") { req in
            seen = req
            return (200, self.envelope(["reset": ["requested": true, "expiresAt": "2026-11-13T01:00:00Z"]]))
        }
        let result = try await gate.passwordReset.request(email: "user@example.test")
        XCTAssertEqual(seen?.url?.absoluteString, "\(base)/password-reset/request")
        XCTAssertNil(seen?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(try body(seen)["email"] as? String, "user@example.test")
        XCTAssertTrue(result.reset.requested)
        XCTAssertNil(result.debugToken)
    }

    func testPasswordResetRequestWithNoMailRelayThrows503() async throws {
        StubURLProtocol.register(method: "POST", pathSuffix: "request") { _ in
            (503, jsonData(["code": "K9O_EMAIL_NOT_CONFIGURED", "message": "no relay"]))
        }
        do {
            _ = try await gate.passwordReset.request(email: "user@example.test")
            XCTFail("expected a throw")
        } catch let error as K9OGateError {
            XCTAssertEqual(error.statusCode, 503)
            XCTAssertEqual(error.code, "K9O_EMAIL_NOT_CONFIGURED")
        }
    }

    func testPasswordResetRedeemReadsASessionOrAnMfaChallenge() async throws {
        var seen: URLRequest?
        StubURLProtocol.register(method: "POST", pathSuffix: "redeem") { req in
            seen = req
            return (200, self.envelope(["redeemed": true, "endUserId": "eu_1", "session": mockSession]))
        }
        let ok = try await gate.passwordReset.redeem(token: "tok", newPassword: "new-pass")
        XCTAssertEqual(seen?.url?.absoluteString, "\(base)/password-reset/redeem")
        XCTAssertEqual(try body(seen)["newPassword"] as? String, "new-pass")
        XCTAssertEqual(ok.endUserId, "eu_1")
        XCTAssertNotNil(ok.session)
        XCTAssertNil(ok.mfa)

        StubURLProtocol.register(method: "POST", pathSuffix: "redeem") { _ in
            (200, self.envelope([
                "redeemed": true, "endUserId": "eu_1",
                "mfa": ["required": true, "challengeId": "ch_9", "expiresAt": "2026-11-13T00:10:00Z",
                        "methodsAvailable": ["totp"], "resident": ["region": "de01", "origin": "https://acme.api-de01.example.test"]],
            ]))
        }
        let challenged = try await gate.passwordReset.redeem(token: "tok", newPassword: "new-pass")
        XCTAssertNil(challenged.session)
        XCTAssertEqual(challenged.mfa?.challengeId, "ch_9")
        XCTAssertEqual(challenged.mfa?.resident.region, "de01")
    }

    // MARK: - invitations

    func testInvitationRedeemSendsTokenPasswordAndDisplayName() async throws {
        var seen: URLRequest?
        StubURLProtocol.register(method: "POST", pathSuffix: "redeem") { req in
            seen = req
            return (200, self.envelope(["redeemed": true, "user": ["id": "eu_2", "email": "new@example.test"], "session": mockSession]))
        }
        let result = try await gate.invitations.redeem(token: "inv", password: "pw", displayName: "New User")
        XCTAssertEqual(seen?.url?.absoluteString, "\(base)/invitations/redeem")
        XCTAssertNil(seen?.value(forHTTPHeaderField: "Authorization"))
        let sent = try body(seen)
        XCTAssertEqual(sent["token"] as? String, "inv")
        XCTAssertEqual(sent["displayName"] as? String, "New User")
        XCTAssertEqual(result.user, K9OInvitationRedemption.User(id: "eu_2", email: "new@example.test"))
        XCTAssertEqual(result.session.expiresAt, "2099-01-01T00:00:00Z")
    }

    // MARK: - verify session

    func testVerifySessionSendsTheTokenInTheBodyAndTheBearerInTheHeader() async throws {
        var seen: URLRequest?
        StubURLProtocol.register(method: "POST", pathSuffix: "verify-session") { req in
            seen = req
            return (200, self.envelope(["valid": true, "claims": ["subjectId": "eu_1", "projectId": "proj_1", "expiresAt": "2099-01-01T00:00:00Z"]]))
        }
        let result = try await gate.verifySession(token: "at_user", bearerToken: "backend_token")
        XCTAssertEqual(seen?.url?.absoluteString, "\(base)/verify-session")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer backend_token")
        XCTAssertEqual(try body(seen)["token"] as? String, "at_user")
        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.claims?.subjectId, "eu_1")
    }

    func testAnInvalidTokenIsAnAnswerNotAnError() async throws {
        StubURLProtocol.register(method: "POST", pathSuffix: "verify-session") { _ in
            (200, self.envelope(["valid": false, "reason": "expired"]))
        }
        let result = try await gate.verifySession(token: "old", bearerToken: "backend_token")
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.reason, "expired")
        XCTAssertNil(result.claims)
    }
}
