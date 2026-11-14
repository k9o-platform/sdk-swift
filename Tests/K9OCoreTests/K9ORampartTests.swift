import XCTest
import CryptoKit
@testable import K9OCore

private let projectId = "proj_01hxyz"
private let issuer = "https://api.k9o.io/rampart"
private let nowDate = Date(timeIntervalSince1970: 1_792_238_400)  // fixed clock
private let nowS = Int(nowDate.timeIntervalSince1970)
private let baseInput: K9OJSON = ["text": "hello", "n": 1, "nested": ["b": [1, 2], "a": nil]]

private func b64u(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
private func b64u(_ s: String) -> String { b64u(Data(s.utf8)) }
private func jsonText(_ o: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
}

private struct Signer {
    let kid: String
    let key = Curve25519.Signing.PrivateKey()
    init(_ kid: String) { self.kid = kid }
    var jwk: K9ORampartJwk {
        K9ORampartJwk(kty: "OKP", crv: "Ed25519", x: b64u(key.publicKey.rawRepresentation), kid: kid, alg: "EdDSA", use: "sig")
    }
    var jwkJSON: [String: Any] { ["kty": "OKP", "crv": "Ed25519", "x": b64u(key.publicKey.rawRepresentation), "kid": kid, "alg": "EdDSA", "use": "sig"] }

    /// `header` / `claims` overrides; a value of NSNull().removes the member.
    func sign(header: [String: Any] = [:], claims: [String: Any] = [:], over: K9OJSON? = nil) -> String {
        var h: [String: Any] = ["alg": "EdDSA", "kid": kid, "typ": "k9o.rampart.classify.v1"]
        for (k, v) in header { if v is NSNull { h[k] = nil } else { h[k] = v } }
        var c: [String: Any] = [
            "iss": issuer, "iat": nowS, "exp": nowS + 3600,
            "input_sha256": k9oSha256Hex(Data(try! K9OJcs.canonicalize(over ?? baseInput).utf8)),
            "classification": "suspicious", "risk_bp": 6200, "confidence_bp": 8100, "categories": ["prompt_injection"],
            "project_id": projectId, "calibration_version": "cal-1",
        ]
        for (k, v) in claims { if v is NSNull { c[k] = nil } else { c[k] = v } }
        let signingInput = "\(b64u(jsonText(h))).\(b64u(jsonText(c)))"
        let sig = try! key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(b64u(sig))"
    }
}

private final class Net: @unchecked Sendable {
    var requests: [URLRequest] = []
    var jwksCount: Int { requests.filter { $0.url?.path == "/rampart/jwks" }.count }
    var feed: () -> (Int, [String: Any]) = { (500, [:]) }
    var classify: () -> (Int, [String: Any]) = { (500, [:]) }
    var transport: K9OTransport {
        { [self] req in
            requests.append(req)
            let (status, body) = req.url!.path == "/rampart/jwks" ? feed() : classify()
            let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            return (try! JSONSerialization.data(withJSONObject: body), resp)
        }
    }
}

private func feedBody(_ keys: [[String: Any]], issuer: String? = issuer) -> [String: Any] {
    var b: [String: Any] = ["keys": keys, "meta": ["context": ["requestId": "r"]]]
    if let issuer { b["issuer"] = issuer }
    return b
}

private let verdictBody: [String: Any] = [
    "classification": "suspicious", "riskScore": 6200, "confidence": 8100, "categories": ["prompt_injection"],
    "calibrationVersion": "cal-1", "classificationReceipt": "a.b.c",
]

private func reason(_ fn: () async throws -> K9ORampartVerified, file: StaticString = #filePath, line: UInt = #line) async -> K9ORampartReceiptReason? {
    do { _ = try await fn() } catch let e as K9ORampartReceiptError { return e.reason } catch { XCTFail("wrong error \(error)", file: file, line: line); return nil }
    XCTFail("expected a refusal", file: file, line: line)
    return nil
}

private func opts(_ s: Signer, keys: [K9ORampartJwk]? = nil, _ tweak: (inout K9ORampartVerifyOptions) -> Void = { _ in }) -> K9ORampartVerifyOptions {
    var o = K9ORampartVerifyOptions(keys: K9ORampartJwks(keys: keys ?? [s.jwk], issuer: issuer), projectId: projectId, now: { nowDate })
    tweak(&o)
    return o
}

private func tamper(_ s: Signer, _ edit: (inout [String: Any], inout Data) -> Void) -> String {
    let parts = s.sign().split(separator: ".").map(String.init)
    var claims = try! JSONSerialization.jsonObject(with: Data(base64Encoded: pad(parts[1]))!) as! [String: Any]
    var sig = Data(base64Encoded: pad(parts[2]))!
    edit(&claims, &sig)
    return "\(parts[0]).\(b64u(jsonText(claims))).\(b64u(sig))"
}
private func pad(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    t += String(repeating: "=", count: (4 - t.count % 4) % 4)
    return t
}


final class K9ORampartTests: XCTestCase {
    // MARK: classify

    func testClassifyPostsInputAndLabelAndReturnsVerdictAsReceived() async throws {
        let net = Net()
        net.classify = { (200, ["data": verdictBody.merging(["projectId": projectId]) { $1 }, "meta": [String: Any]()]) }
        let c = makeClient(net.transport, slug: "portal")
        let r = try await c.rampart.classify(["text": "hi"], label: "chat")
        let req = net.requests[0]
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://acme.api-de01.k9o.io/@portal/rampart/classify")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok_abc")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(body["input"] as? [String: String], ["text": "hi"])
        XCTAssertEqual(body["label"] as? String, "chat")
        XCTAssertEqual(body.count, 2)
        XCTAssertEqual(r.data.classification, .suspicious)
        XCTAssertEqual(r.data.riskScore, 6200)
        XCTAssertEqual(r.data.confidence, 8100)
        XCTAssertEqual(r.data.categories, ["prompt_injection"])
        XCTAssertEqual(r.data.calibrationVersion, "cal-1")
        XCTAssertEqual(r.data.classificationReceipt, "a.b.c")
        XCTAssertEqual(r.data.projectId, projectId)
    }

    func testClassifyOmitsLabelAndProjectIdWhenAbsent() async throws {
        let net = Net()
        net.classify = { (200, ["data": verdictBody, "meta": [String: Any]()]) }
        let r = try await makeClient(net.transport).rampart.classify(["text": "hi"])
        let body = try JSONSerialization.jsonObject(with: net.requests[0].httpBody!) as! [String: Any]
        XCTAssertEqual(Set(body.keys), ["input"])
        XCTAssertNil(r.data.projectId)
    }

    func test503IsATypedErrorNeverAVerdict() async {
        let net = Net()
        net.classify = { (503, ["code": "K9O_RAMPART_CLASSIFIER_UNAVAILABLE", "message": "down", "context": ["cause": "no_endpoint_configured"], "recommendation": NSNull()]) }
        await expectError("K9O_RAMPART_CLASSIFIER_UNAVAILABLE") {
            _ = try await makeClient(net.transport).rampart.classify(["text": "hi"])
        }
        do { _ = try await makeClient(net.transport).rampart.classify(["text": "hi"]) } catch let e as K9OError { XCTAssertEqual(e.status, 503) } catch {}
    }

    func test413InputTooLongIsATypedErrorWithTheCode() async {
        let net = Net()
        net.classify = { (413, ["code": "K9O_RAMPART_INPUT_TOO_LONG", "message": "too long", "context": ["reason": "rampart_input_too_long"], "recommendation": NSNull()]) }
        do {
            _ = try await makeClient(net.transport).rampart.classify(["text": "long"])
            XCTFail("expected an error")
        } catch let e as K9OError {
            XCTAssertEqual(e.code, "K9O_RAMPART_INPUT_TOO_LONG")
            XCTAssertEqual(e.code, K9ORampart.inputTooLongCode)
            XCTAssertEqual(e.status, 413)
            XCTAssertEqual(e.context, ["reason": "rampart_input_too_long"])
        } catch { XCTFail("wrong error \(error)") }
    }

    func testClassifyChecksArgumentsBeforeSending() async {
        let net = Net()
        net.classify = { (200, ["data": verdictBody, "meta": [String: Any]()]) }
        let c = makeClient(net.transport)
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await c.rampart.classify([:], label: "") }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await c.rampart.classify([:], label: String(repeating: "x", count: 129)) }
        _ = try? await c.rampart.classify([:], label: String(repeating: "x", count: 128))
        XCTAssertEqual(net.requests.count, 1, "128 characters is allowed; the two bad labels sent nothing")
        await expectError("K9O_MISSING_PROJECT_CONTEXT") {
            _ = try await makeClient(net.transport, slug: nil).rampart.classify([:])
        }
        XCTAssertEqual(net.requests.count, 1)
    }

    func testClassifyDoesNotPrevalidateTheInput() async {
        let net = Net()
        net.classify = { (400, ["code": "K9O_VALIDATION_FAILED", "message": "bad input", "context": [String: Any](), "recommendation": NSNull()]) }
        await expectError("K9O_VALIDATION_FAILED") { _ = try await makeClient(net.transport).rampart.classify(["x": 1.5]) }
        XCTAssertEqual(net.requests.count, 1)
    }

    // MARK: jwks

    func testJwksReadsPublicPathWithNoProjectPrefixAndNoCredential() async throws {
        let s = Signer("k1")
        let net = Net()
        net.feed = { (200, feedBody([s.jwkJSON])) }
        let r = try await makeClient(net.transport).rampart.jwks()
        XCTAssertEqual(net.requests.map { $0.httpMethod }, ["GET"])
        XCTAssertEqual(net.requests[0].url?.absoluteString, "https://acme.api-de01.k9o.io/rampart/jwks")
        XCTAssertNil(net.requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(r.keys, [s.jwk])
        XCTAssertEqual(r.issuer, issuer)
    }

    func testJwksIssuerIsNilWhenNotAdvertised() async throws {
        let net = Net()
        net.feed = { (200, feedBody([Signer("k1").jwkJSON], issuer: nil)) }
        let feed = try await makeClient(net.transport).rampart.jwks()
        XCTAssertNil(feed.issuer)
    }

    func testJwksRefusesABodyThatIsNotAKeyFeed() async {
        let net = Net()
        net.feed = { (200, ["data": [], "meta": [String: Any]()]) }
        await expectError("K9O_INTERNAL_ERROR") { _ = try await makeClient(net.transport).rampart.jwks() }
    }

    // MARK: verifyReceipt

    func testAcceptsAGoodReceiptAndReturnsTheVerifiedClaims() async throws {
        let s = Signer("k1")
        let v = try await makeClient(Net().transport).rampart.verifyReceipt(s.sign(), input: baseInput, options: opts(s))
        XCTAssertEqual(v, K9ORampartVerified(
            classification: .suspicious, riskScore: 6200, confidence: 8100, categories: ["prompt_injection"],
            calibrationVersion: "cal-1", projectId: projectId,
            inputSha256: k9oSha256Hex(Data(try K9OJcs.canonicalize(baseInput).utf8)), issuer: issuer,
            issuedAt: Double(nowS), expiresAt: Double(nowS + 3600), kid: "k1", windows: 1))
    }

    func testMatchesTheInputByCanonicalFormNotKeyOrder() async throws {
        let s = Signer("k1")
        let reordered: K9OJSON = ["nested": ["a": nil, "b": [1, 2]], "n": 1, "text": "hello"]
        let v = try await makeClient(Net().transport).rampart.verifyReceipt(s.sign(), input: reordered, options: opts(s))
        XCTAssertEqual(v.classification, .suspicious)
    }

    func testTakesTheClassifyResultAndComparesTheProjectItCarries() async throws {
        let s = Signer("k1")
        let c = makeClient(Net().transport)
        let receipt = s.sign()
        func verdict(_ pid: String?) -> K9ORampartVerdict {
            var body = verdictBody.merging(["classificationReceipt": receipt]) { $1 }
            if let pid { body["projectId"] = pid }
            return try! JSONDecoder().decode(K9ORampartVerdict.self, from: JSONSerialization.data(withJSONObject: body))
        }
        var base = opts(s); base.projectId = nil
        let ok = try await c.rampart.verifyReceipt(verdict(projectId), input: baseInput, options: base)
        XCTAssertEqual(ok.projectId, projectId)
        let other = await reason { try await c.rampart.verifyReceipt(verdict("proj_other"), input: baseInput, options: base) }
        XCTAssertEqual(other, .project)
        let none = await reason { try await c.rampart.verifyReceipt(verdict(nil), input: baseInput, options: base) }
        XCTAssertEqual(none, .projectUnknown)
        // the option wins over the carried id
        let win = try await c.rampart.verifyReceipt(verdict("proj_other"), input: baseInput, options: opts(s))
        XCTAssertEqual(win.projectId, projectId)
    }

    func testEndToEndClassifyThenVerifyWithTheFeedFetchedByTheSdk() async throws {
        let s = Signer("k1")
        let receipt = s.sign()
        let net = Net()
        net.classify = { (200, ["data": verdictBody.merging(["classificationReceipt": receipt, "projectId": projectId]) { $1 }, "meta": [String: Any]()]) }
        net.feed = { (200, feedBody([s.jwkJSON])) }
        let c = makeClient(net.transport)
        let r = try await c.rampart.classify(["text": "hello", "n": 1, "nested": ["b": [1, 2], "a": nil]])
        let v = try await c.rampart.verifyReceipt(r, input: baseInput, options: K9ORampartVerifyOptions(now: { nowDate }))
        XCTAssertEqual(v.issuer, issuer)
    }

    func testBareReceiptWithoutProjectIsProjectUnknown() async throws {
        let s = Signer("k1")
        let c = makeClient(Net().transport)
        let receipt = s.sign()
        let r = await reason { try await c.rampart.verifyReceipt(receipt, input: baseInput, options: opts(s) { $0.projectId = nil }) }
        XCTAssertEqual(r, .projectUnknown)
        let ok = try await c.rampart.verifyReceipt(receipt, input: baseInput, options: opts(s))
        XCTAssertEqual(ok.projectId, projectId)
    }

    func testIssuerComesFromTheFeedNeverFromTheBaseUrl() async throws {
        let s = Signer("k1")
        let net = Net()
        net.feed = { (200, feedBody([s.jwkJSON], issuer: "https://id.corp.internal/rampart")) }
        let c = K9OCoreClient(baseURL: URL(string: "https://acme.api-de01.corp.internal")!, projectSlug: "p", accessToken: "t", transport: net.transport)
        let o = K9ORampartVerifyOptions(projectId: projectId, now: { nowDate })
        let good = try await c.rampart.verifyReceipt(s.sign(claims: ["iss": "https://id.corp.internal/rampart"]), input: baseInput, options: o)
        XCTAssertEqual(good.issuer, "https://id.corp.internal/rampart")
        let derived = s.sign(claims: ["iss": "https://api.corp.internal/rampart"])
        let r = await reason { try await c.rampart.verifyReceipt(derived, input: baseInput, options: o) }
        XCTAssertEqual(r, .issuer)
    }

    func testNoAdvertisedIssuerAndNoOptionIsRefusedAsIssuer() async throws {
        let s = Signer("k1")
        let net = Net()
        net.feed = { (200, feedBody([s.jwkJSON], issuer: nil)) }
        let c = makeClient(net.transport)
        let receipt = s.sign()
        do {
            _ = try await c.rampart.verifyReceipt(receipt, input: baseInput, options: K9ORampartVerifyOptions(projectId: projectId, now: { nowDate }))
            XCTFail("expected a refusal")
        } catch let e as K9ORampartReceiptError {
            XCTAssertEqual(e.reason, .issuer)
            XCTAssertTrue(e.detail.contains("no issuer is advertised"))
        }
        let injected = K9ORampartVerifyOptions(keys: K9ORampartJwks(keys: [s.jwk]), projectId: projectId, now: { nowDate })
        let r = await reason { try await c.rampart.verifyReceipt(receipt, input: baseInput, options: injected) }
        XCTAssertEqual(r, .issuer)
    }

    func testIssuerOptionOverridesTheFeed() async throws {
        let s = Signer("k1")
        let net = Net()
        net.feed = { (200, feedBody([s.jwkJSON])) }
        let c = makeClient(net.transport)
        let other = "https://other.example/rampart"
        let receipt = s.sign(claims: ["iss": other])
        let o = K9ORampartVerifyOptions(projectId: projectId, now: { nowDate })
        let refused = await reason { try await c.rampart.verifyReceipt(receipt, input: baseInput, options: o) }
        XCTAssertEqual(refused, .issuer)
        var o2 = o; o2.issuer = other
        let v = try await c.rampart.verifyReceipt(receipt, input: baseInput, options: o2)
        XCTAssertEqual(v.issuer, other)
        // and the option is binding against a matching feed
        let mine = s.sign()
        let r = await reason { try await c.rampart.verifyReceipt(mine, input: baseInput, options: o2) }
        XCTAssertEqual(r, .issuer)
    }

    func testInputsThatCannotBeCanonicalisedAreInputHash() async {
        let s = Signer("k1")
        let c = makeClient(Net().transport)
        let receipt = s.sign()
        for bad: K9OJSON in [["x": 1.5], ["x": .number(9007199254740992)], ["x": [0.1]], .number(.nan)] {
            let r = await reason { try await c.rampart.verifyReceipt(receipt, input: bad, options: opts(s)) }
            XCTAssertEqual(r, .inputHash, "\(bad)")
        }
    }

    private struct Case {
        let name: String
        let expected: K9ORampartReceiptReason
        let receipt: (Signer) -> String
        var input: K9OJSON = baseInput
        var keys: ((Signer) -> [K9ORampartJwk])? = nil
    }

    func testEveryRefusalReason() async {
        let cases: [Case] = [
            Case(name: "a kid the key set does not hold", expected: .keyUnknown, receipt: { $0.sign(header: ["kid": "nope"]) }),
            Case(name: "a key of another type", expected: .keyUnknown, receipt: { $0.sign() },
                 keys: { [K9ORampartJwk(kty: "RSA", crv: "Ed25519", x: $0.jwk.x, kid: "k1")] }),
            Case(name: "a key whose x is not 32 bytes", expected: .keyUnknown, receipt: { $0.sign() },
                 keys: { _ in [K9ORampartJwk(kty: "OKP", crv: "Ed25519", x: "AAAA", kid: "k1")] }),
            Case(name: "alg HS256", expected: .alg, receipt: { $0.sign(header: ["alg": "HS256"]) }),
            Case(name: "alg none", expected: .alg, receipt: { $0.sign(header: ["alg": "none"]) }),
            Case(name: "typ JWT", expected: .typ, receipt: { $0.sign(header: ["typ": "JWT"]) }),
            Case(name: "another typ version", expected: .typ, receipt: { $0.sign(header: ["typ": "k9o.rampart.classify.v2"]) }),
            Case(name: "no typ", expected: .typ, receipt: { $0.sign(header: ["typ": NSNull()]) }),
            Case(name: "another issuer", expected: .issuer, receipt: { $0.sign(claims: ["iss": "https://evil.example/rampart"]) }),
            Case(name: "another project", expected: .project, receipt: { $0.sign(claims: ["project_id": "proj_other"]) }),
            Case(name: "a project id that is a slug", expected: .project, receipt: { $0.sign(claims: ["project_id": "portal"]) }),
            Case(name: "an input with a fraction", expected: .inputHash, receipt: { $0.sign() }, input: ["text": "hello", "n": 1.5]),
            Case(name: "an input above 2^53-1", expected: .inputHash, receipt: { $0.sign() }, input: ["n": .number(9007199254740992)]),
            Case(name: "expired past the skew", expected: .expired, receipt: { $0.sign(claims: ["iat": nowS - 7200, "exp": nowS - 61]) }),
            Case(name: "issued in the future past the skew", expected: .notYetValid, receipt: { $0.sign(claims: ["iat": nowS + 61, "exp": nowS + 3600]) }),
            Case(name: "another input", expected: .inputHash, receipt: { $0.sign() }, input: ["text": "different"]),
            Case(name: "a tampered signature", expected: .signature, receipt: { s in tamper(s) { _, sig in sig[0] ^= 1 } }),
            Case(name: "tampered claims", expected: .signature, receipt: { s in tamper(s) { c, _ in c["classification"] = "clear" } }),
            Case(name: "a short signature", expected: .signature, receipt: { s in
                let p = s.sign().split(separator: ".").map(String.init); return "\(p[0]).\(p[1]).AAAA" }),
            Case(name: "a signature by another key under the same kid", expected: .signature, receipt: { _ in Signer("k1").sign() }),
            Case(name: "two parts", expected: .malformed, receipt: { _ in "only.two" }),
            Case(name: "four parts", expected: .malformed, receipt: { _ in "a.b.c.d" }),
            Case(name: "an empty part", expected: .malformed, receipt: { _ in "a..c" }),
            Case(name: "characters outside base64url", expected: .malformed, receipt: { _ in "!!!.@@@.###" }),
            Case(name: "a header that is not an object", expected: .malformed, receipt: { _ in "\(b64u("[]")).\(b64u("{}")).AAAA" }),
            Case(name: "no kid", expected: .malformed, receipt: { _ in "\(b64u("{}")).\(b64u("{}")).AAAA" }),
            Case(name: "a critical header parameter", expected: .malformed, receipt: { $0.sign(header: ["crit": ["x"]]) }),
            Case(name: "a non-numeric exp", expected: .malformed, receipt: { $0.sign(claims: ["exp": "soon"]) }),
            Case(name: "an unknown classification", expected: .malformed, receipt: { $0.sign(claims: ["classification": "fine"]) }),
            Case(name: "a risk outside 0..10000", expected: .malformed, receipt: { $0.sign(claims: ["risk_bp": 10001]) }),
            Case(name: "a missing digest", expected: .malformed, receipt: { $0.sign(claims: ["input_sha256": NSNull()]) }),
        ]
        var covered = Set<K9ORampartReceiptReason>()
        for c in cases {
            let s = Signer("k1")
            let keys = c.keys?(s) ?? [s.jwk]
            let r = await reason { try await makeClient(Net().transport).rampart.verifyReceipt(c.receipt(s), input: c.input, options: opts(s, keys: keys)) }
            XCTAssertEqual(r, c.expected, c.name)
            covered.insert(c.expected)
        }
        covered.insert(.keyUnavailable)  // covered by testKeyUnavailable
        covered.insert(.projectUnknown)  // covered by the project tests above
        XCTAssertEqual(covered, Set(K9ORampartReceiptReason.allCases))
    }

    func testWindowsClaimPresentAbsentInvalidAndUnknownClaims() async throws {
        let s = Signer("k1")
        let c = makeClient(Net().transport)
        let three = try await c.rampart.verifyReceipt(s.sign(claims: ["windows": 3]), input: baseInput, options: opts(s))
        XCTAssertEqual(three.windows, 3)
        let absent = try await c.rampart.verifyReceipt(s.sign(), input: baseInput, options: opts(s))
        XCTAssertEqual(absent.windows, 1)
        let unknown = try await c.rampart.verifyReceipt(s.sign(claims: ["future_claim": ["x": 1]]), input: baseInput, options: opts(s))
        XCTAssertEqual(unknown.windows, 1)
        for bad: Any in [0, -1, 1.5, "2", true, [1], ["a": 1]] {
            let h = s.sign(claims: ["windows": bad])
            let r = await reason { try await c.rampart.verifyReceipt(h, input: baseInput, options: opts(s)) }
            XCTAssertEqual(r, .malformed, "\(bad)")
        }
    }

    func testClockSkewAtBothEnds() async throws {
        let s = Signer("k1")
        let c = makeClient(Net().transport)
        let late = s.sign(claims: ["iat": nowS - 3600, "exp": nowS - 60])
        let okLate = try await c.rampart.verifyReceipt(late, input: baseInput, options: opts(s))
        XCTAssertEqual(okLate.kid, "k1")
        let l = await reason { try await c.rampart.verifyReceipt(late, input: baseInput, options: opts(s) { $0.clockSkewSeconds = 10 }) }
        XCTAssertEqual(l, .expired)
        let early = s.sign(claims: ["iat": nowS + 60, "exp": nowS + 3600])
        let okEarly = try await c.rampart.verifyReceipt(early, input: baseInput, options: opts(s))
        XCTAssertEqual(okEarly.kid, "k1")
        let e = await reason { try await c.rampart.verifyReceipt(early, input: baseInput, options: opts(s) { $0.clockSkewSeconds = 0 }) }
        XCTAssertEqual(e, .notYetValid)
    }

    func testVerdictComesFromTheSignedClaims() async throws {
        let s = Signer("k1")
        let v = try await makeClient(Net().transport).rampart.verifyReceipt(
            s.sign(claims: ["classification": "malicious", "risk_bp": 9900]), input: baseInput, options: opts(s))
        XCTAssertEqual(v.classification, .malicious)
        XCTAssertEqual(v.riskScore, 9900)
    }

    func testKeyCarriedInsideTheReceiptIsNeverUsed() async {
        let real = Signer("k1")
        let attacker = Signer("k1")
        let receipt = attacker.sign(header: ["jwk": attacker.jwkJSON])
        let r = await reason { try await makeClient(Net().transport).rampart.verifyReceipt(receipt, input: baseInput, options: opts(real)) }
        XCTAssertEqual(r, .signature)
    }

    // MARK: the key feed

    func testFeedIsFetchedOnceAndKept() async throws {
        let s = Signer("k1")
        let net = Net()
        net.feed = { (200, feedBody([s.jwkJSON])) }
        let c = makeClient(net.transport)
        let receipt = s.sign()
        let o = K9ORampartVerifyOptions(projectId: projectId, now: { nowDate })
        for _ in 0..<3 { _ = try await c.rampart.verifyReceipt(receipt, input: baseInput, options: o) }
        XCTAssertEqual(net.jwksCount, 1)
        XCTAssertTrue(net.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    func testUnknownKidRefetchesOnceAndFindsTheRotatedKey() async throws {
        let old = Signer("k1"), rotated = Signer("k2")
        let net = Net()
        nonisolated(unsafe) var published = [old.jwkJSON]
        net.feed = { (200, feedBody(published)) }
        let c = makeClient(net.transport)
        let o = K9ORampartVerifyOptions(projectId: projectId, now: { nowDate })
        _ = try await c.rampart.verifyReceipt(old.sign(), input: baseInput, options: o)
        published = [old.jwkJSON, rotated.jwkJSON]
        let v = try await c.rampart.verifyReceipt(rotated.sign(), input: baseInput, options: o)
        XCTAssertEqual(v.kid, "k2")
        XCTAssertEqual(net.jwksCount, 2)
    }

    func testAKidThatNeverAppearsRefetchesOncePerCall() async throws {
        let known = Signer("k1"), stranger = Signer("zz")
        let net = Net()
        net.feed = { (200, feedBody([known.jwkJSON])) }
        let c = makeClient(net.transport)
        let o = K9ORampartVerifyOptions(projectId: projectId, now: { nowDate })
        _ = try await c.rampart.verifyReceipt(known.sign(), input: baseInput, options: o)
        let r = await reason { try await c.rampart.verifyReceipt(stranger.sign(), input: baseInput, options: o) }
        XCTAssertEqual(r, .keyUnknown)
        XCTAssertEqual(net.jwksCount, 2, "1 initial + 1 refetch")
    }

    func testNoSecondFetchWhenTheFirstFetchAlreadyLacksTheKid() async {
        let known = Signer("k1"), stranger = Signer("zz")
        let net = Net()
        net.feed = { (200, feedBody([known.jwkJSON])) }
        let r = await reason { try await makeClient(net.transport).rampart.verifyReceipt(
            stranger.sign(), input: baseInput, options: K9ORampartVerifyOptions(projectId: projectId, now: { nowDate })) }
        XCTAssertEqual(r, .keyUnknown)
        XCTAssertEqual(net.jwksCount, 1)
    }

    func testInjectedKeysNeverFetch() async throws {
        let s = Signer("k1")
        let net = Net()
        net.feed = { (200, feedBody([s.jwkJSON])) }
        let c = makeClient(net.transport)
        _ = try await c.rampart.verifyReceipt(s.sign(), input: baseInput, options: opts(s))
        let r = await reason { try await c.rampart.verifyReceipt(s.sign(header: ["kid": "x"]), input: baseInput, options: opts(s)) }
        XCTAssertEqual(r, .keyUnknown)
        XCTAssertEqual(net.requests.count, 0)
    }

    func testKeyUnavailableWhenTheFeedCannotBeRead() async {
        let s = Signer("k1")
        let net = Net()
        net.feed = { (503, ["code": "K9O_UPSTREAM_UNAVAILABLE", "message": "down", "context": [String: Any](), "recommendation": NSNull()]) }
        let r = await reason { try await makeClient(net.transport).rampart.verifyReceipt(
            s.sign(), input: baseInput, options: K9ORampartVerifyOptions(projectId: projectId, now: { nowDate })) }
        XCTAssertEqual(r, .keyUnavailable)
    }
}
