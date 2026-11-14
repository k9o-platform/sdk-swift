import Foundation
import CryptoKit

public enum K9ORampartClassification: String, Codable, Sendable, Equatable {
    case clear, suspicious, malicious
}

/// The verdict and its receipt, as the gateway sent them. The verdict is not checked until you call `verifyReceipt`.
public struct K9ORampartVerdict: Decodable, Sendable, Equatable {
    public let classification: K9ORampartClassification
    /// Risk in basis points, an integer 0 to 10000.
    public let riskScore: Int
    /// Confidence in basis points, an integer 0 to 10000.
    public let confidence: Int
    public let categories: [String]
    public let calibrationVersion: String
    /// The signed receipt (a compact JWS), exactly as received. Pass the result to `verifyReceipt`.
    public let classificationReceipt: String
    /// The project id (`proj_...`) the receipt names, when the gateway reports it.
    public let projectId: String?
}

/// One public key of the feed (an Ed25519 JWK).
public struct K9ORampartJwk: Sendable, Equatable {
    public let kty: String?
    public let crv: String?
    public let x: String?
    public let kid: String
    public let alg: String?
    public let use: String?
    public init(kty: String?, crv: String? = nil, x: String? = nil, kid: String, alg: String? = nil, use: String? = nil) {
        self.kty = kty; self.crv = crv; self.x = x; self.kid = kid; self.alg = alg; self.use = use
    }
}

/// The key feed: the keys and the issuer receipts carry (`<issuer>/rampart`). `issuer` is nil when the gateway does
/// not advertise one.
public struct K9ORampartJwks: Sendable, Equatable {
    public let keys: [K9ORampartJwk]
    public let issuer: String?
    public init(keys: [K9ORampartJwk], issuer: String? = nil) {
        self.keys = keys
        self.issuer = issuer
    }
}

/// Why a receipt was refused. The set is closed.
public enum K9ORampartReceiptReason: String, Sendable, CaseIterable {
    case malformed
    case keyUnavailable = "key_unavailable"
    case keyUnknown = "key_unknown"
    case alg, typ, signature, issuer, project
    case projectUnknown = "project_unknown"
    case expired
    case notYetValid = "not_yet_valid"
    case inputHash = "input_hash"
}

/// Thrown by `verifyReceipt` for every refusal. There is no partial verdict.
public struct K9ORampartReceiptError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public let reason: K9ORampartReceiptReason
    public let detail: String
    public init(_ reason: K9ORampartReceiptReason, _ detail: String) {
        self.reason = reason
        self.detail = detail
    }
    public var description: String { "rampart receipt refused (\(reason.rawValue)): \(detail)" }
    public var errorDescription: String? { description }
}

public struct K9ORampartVerifyOptions: Sendable {
    /// A key set you already fetched (`jwks()`, which also supplies the issuer). Without it the SDK fetches the feed itself.
    public var keys: K9ORampartJwks?
    /// The issuer the receipt must carry. Default: the issuer the key feed advertises. When neither exists the receipt
    /// is refused (`issuer`).
    public var issuer: String?
    /// The project id the receipt must name. Default: the `projectId` carried by the classify result you pass. A bare
    /// receipt string with neither is refused (`project_unknown`); a different id is refused (`project`).
    public var projectId: String?
    /// Seconds of clock difference tolerated at both ends of the window. Default 60.
    public var clockSkewSeconds: Double
    /// The clock, for tests. Default: the current time.
    public var now: @Sendable () -> Date

    public init(keys: K9ORampartJwks? = nil, issuer: String? = nil, projectId: String? = nil,
                clockSkewSeconds: Double = 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.keys = keys
        self.issuer = issuer
        self.projectId = projectId
        self.clockSkewSeconds = clockSkewSeconds
        self.now = now
    }
}

/// The claims of a receipt that passed every check.
public struct K9ORampartVerified: Sendable, Equatable {
    public let classification: K9ORampartClassification
    public let riskScore: Int
    public let confidence: Int
    public let categories: [String]
    public let calibrationVersion: String
    public let projectId: String
    /// Lowercase hex SHA-256 of the canonical input.
    public let inputSha256: String
    public let issuer: String
    /// Seconds since the epoch.
    public let issuedAt: Double
    public let expiresAt: Double
    public let kid: String
    /// How many windows of the input were scored (1 when it fits one window). A receipt without the claim reads as 1.
    public let windows: Int
}

/// Keeps the key feed for the life of the client; one fetch at a time.
actor K9ORampartFeedCache {
    private(set) var feed: K9ORampartJwks?
    private var inflight: Task<K9ORampartJwks, Error>?

    func refresh(_ fetch: @escaping @Sendable () async throws -> K9ORampartJwks) async throws -> K9ORampartJwks {
        if let task = inflight { return try await task.value }
        let task = Task { try await fetch() }
        inflight = task
        do {
            let f = try await task.value
            feed = f
            inflight = nil
            return f
        } catch {
            inflight = nil
            throw error
        }
    }
}

public struct K9ORampart: Sendable {
    let client: K9OCoreClient

    public static let receiptType = "k9o.rampart.classify.v1"

    /// 503: the classifier could not answer. No verdict was made.
    public static let classifierUnavailableCode = "K9O_RAMPART_CLASSIFIER_UNAVAILABLE"
    /// 413: the input needs more than 16 windows (about 6,000 tokens). `context.reason` is `rampart_input_too_long`.
    /// No verdict was made; send a shorter input.
    public static let inputTooLongCode = "K9O_RAMPART_INPUT_TOO_LONG"

    private struct ClassifyBody: Encodable {
        let input: [String: K9OJSON]
        let label: String?
        private enum Keys: String, CodingKey { case input, label }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(input, forKey: .input)
            if let label { try c.encode(label, forKey: .label) }  // omitted when nil
        }
    }

    /// `POST /@<projectSlug>/rampart/classify`: classify `input` (a JSON object) and get the verdict with its signed
    /// receipt, as received. Rampart is advisory: it blocks nothing, and your code decides what to do.
    ///
    /// `label` is a context label of 1 to 128 characters. The input is sent as given: it is not checked for numbers
    /// the canonical form cannot hold (the server answers a typed 400 for those). A long input is scored in
    /// overlapping windows and the highest injection score decides. Past 16 windows (about 6,000 tokens) the call throws
    /// `K9OError` 413 `K9O_RAMPART_INPUT_TOO_LONG` (`K9ORampart.inputTooLongCode`) and gives no verdict. While the
    /// classifier cannot answer, it throws 503 `K9O_RAMPART_CLASSIFIER_UNAVAILABLE`: you get no verdict, never a default "clear".
    /// Throws `K9O_MISSING_PROJECT_CONTEXT` or `K9O_INVALID_FIELD_VALUE` (no request sent) for a missing project or a
    /// bad label.
    public func classify(_ input: [String: K9OJSON], label: String? = nil) async throws -> K9OEnvelope<K9ORampartVerdict> {
        let slug = try client.requireProject("rampart operations")
        if let label, label.utf16.count < 1 || label.utf16.count > 128 {
            throw K9OError.invalidField("rampart.classify: label must be 1 to 128 characters")
        }
        return try await client.post(path: "/@\(slug)/rampart/classify",
                                     body: ClassifyBody(input: input, label: label), as: K9ORampartVerdict.self)
    }

    /// `GET /rampart/jwks` (public: no credential is sent, no project prefix): the public keys that verify receipts
    /// and the issuer they carry. The feed is also kept for `verifyReceipt`.
    public func jwks() async throws -> K9ORampartJwks {
        let client = self.client
        return try await client.rampartFeed.refresh { try await Self.fetchFeed(client) }
    }

    private static func fetchFeed(_ client: K9OCoreClient) async throws -> K9ORampartJwks {
        let (data, status) = try await client.sendRaw(method: "GET", path: "/rampart/jwks", authenticated: false)
        guard let body = try? JSONDecoder().decode(K9OJSON.self, from: data), case .object(let o) = body else {
            throw K9OError(code: K9OError.internalError, message: "The Rampart key feed did not return JSON", status: status)
        }
        guard case .array(let raw)? = o["keys"] else {
            throw K9OError(code: K9OError.internalError,
                           message: "The Rampart key feed is malformed: expected { keys: [...] }", status: status)
        }
        var keys: [K9ORampartJwk] = []
        for k in raw {
            guard case .object(let m) = k, case .string(let kid)? = m["kid"] else {
                throw K9OError(code: K9OError.internalError,
                               message: "The Rampart key feed is malformed: expected { keys: [...] }", status: status)
            }
            func str(_ name: String) -> String? { if case .string(let s)? = m[name] { return s } else { return nil } }
            keys.append(K9ORampartJwk(kty: str("kty"), crv: str("crv"), x: str("x"), kid: kid, alg: str("alg"), use: str("use")))
        }
        var issuer: String?
        if case .string(let i)? = o["issuer"], !i.isEmpty { issuer = i }
        return K9ORampartJwks(keys: keys, issuer: issuer)
    }

    /// Check a receipt against the `input` you classified and return its verified claims. Pass the classify result (it
    /// carries the receipt and its `projectId`) or a bare receipt string (then also pass `options.projectId`). Throws
    /// `K9ORampartReceiptError` on any failure; see `K9ORampartReceiptReason`. Keys come from `options.keys`, or the SDK
    /// fetches the feed once and keeps it for the life of the client, fetching again once when a `kid` is not in it.
    /// The checks run in this order: key by `kid`, `alg`, `typ`, signature, issuer, project, time window, input hash.
    public func verifyReceipt(_ result: K9OEnvelope<K9ORampartVerdict>, input: K9OJSON,
                              options: K9ORampartVerifyOptions = .init()) async throws -> K9ORampartVerified {
        try await verifyReceipt(result.data, input: input, options: options)
    }

    public func verifyReceipt(_ verdict: K9ORampartVerdict, input: K9OJSON,
                              options: K9ORampartVerifyOptions = .init()) async throws -> K9ORampartVerified {
        try await verify(receipt: verdict.classificationReceipt, carriedProjectId: verdict.projectId, input: input, options: options)
    }

    public func verifyReceipt(_ receipt: String, input: K9OJSON,
                              options: K9ORampartVerifyOptions = .init()) async throws -> K9ORampartVerified {
        try await verify(receipt: receipt, carriedProjectId: nil, input: input, options: options)
    }

    // MARK: verification

    private static func b64urlDecode(_ s: String) throws -> Data {
        let ok = s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }
        guard ok, s.utf8.count % 4 != 1 else { throw K9ORampartReceiptError(.malformed, "a receipt part is not base64url") }
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        t += String(repeating: "=", count: (4 - t.utf8.count % 4) % 4)
        guard let d = Data(base64Encoded: t) else { throw K9ORampartReceiptError(.malformed, "a receipt part is not base64url") }
        return d
    }

    private static func b64urlJson(_ s: String, _ what: String) throws -> [String: K9OJSON] {
        let data = try b64urlDecode(s)
        guard let v = try? JSONDecoder().decode(K9OJSON.self, from: data) else {
            throw K9ORampartReceiptError(.malformed, "the receipt \(what) is not JSON")
        }
        guard case .object(let o) = v else { throw K9ORampartReceiptError(.malformed, "the receipt \(what) is not an object") }
        return o
    }

    private static func isBp(_ v: K9OJSON?) -> Int? {
        if case .number(let n)? = v, n.isFinite, n == n.rounded(), n >= 0, n <= 10000 { return Int(n) }
        return nil
    }

    private func keyFor(kid: String, injected: K9ORampartJwks?) async throws -> (K9ORampartJwk, String?) {
        if let injected {
            guard let k = injected.keys.first(where: { $0.kid == kid }) else {
                throw K9ORampartReceiptError(.keyUnknown, "no key with the receipt's kid in the key set you passed")
            }
            return (k, injected.issuer)
        }
        do {
            var fresh = false
            var feed = await client.rampartFeed.feed
            if feed == nil { feed = try await jwks(); fresh = true }
            var k = feed!.keys.first(where: { $0.kid == kid })
            if k == nil && !fresh { feed = try await jwks(); k = feed!.keys.first(where: { $0.kid == kid }) }  // refetch once
            guard let k else { throw K9ORampartReceiptError(.keyUnknown, "no key with the receipt's kid in the key feed") }
            return (k, feed!.issuer)
        } catch let e as K9ORampartReceiptError {
            throw e
        } catch {
            throw K9ORampartReceiptError(.keyUnavailable, "the key feed could not be read")
        }
    }

    private func verify(receipt: String, carriedProjectId: String?, input: K9OJSON,
                        options: K9ORampartVerifyOptions) async throws -> K9ORampartVerified {
        let parts = receipt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts.contains(where: { $0.isEmpty }) else {
            throw K9ORampartReceiptError(.malformed, "a receipt has three dot-separated parts")
        }
        let header = try Self.b64urlJson(parts[0], "header")
        let claims = try Self.b64urlJson(parts[1], "payload")
        let signature = try Self.b64urlDecode(parts[2])
        if header["crit"] != nil || header["b64"] == .bool(false) {
            throw K9ORampartReceiptError(.malformed, "the header carries unsupported critical parameters")
        }

        // 1. The key is chosen by the header kid, from the feed; a key inside the receipt is never used.
        guard case .string(let kid)? = header["kid"] else { throw K9ORampartReceiptError(.malformed, "the header has no kid") }
        let (jwk, feedIssuer) = try await keyFor(kid: kid, injected: options.keys)
        // 2. and 3. Algorithm and type.
        guard header["alg"] == .string("EdDSA") else { throw K9ORampartReceiptError(.alg, "the algorithm is not EdDSA") }
        guard header["typ"] == .string(Self.receiptType) else {
            throw K9ORampartReceiptError(.typ, "the type is not \(Self.receiptType)")
        }
        // Signature, before any claim is trusted.
        guard jwk.kty == "OKP", jwk.crv == "Ed25519", let x = jwk.x else {
            throw K9ORampartReceiptError(.keyUnknown, "the key named by the receipt is not an Ed25519 key")
        }
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: try Self.b64urlDecode(x))
        } catch {
            throw K9ORampartReceiptError(.keyUnknown, "the key named by the receipt could not be loaded")
        }
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard signature.count == 64, key.isValidSignature(signature, for: signingInput) else {
            throw K9ORampartReceiptError(.signature, "the signature does not verify")
        }

        // 4. Issuer, project, time window.
        guard let issuer = options.issuer ?? feedIssuer else {
            throw K9ORampartReceiptError(.issuer, "no issuer is advertised: the key feed carries none and no issuer option was given")
        }
        guard claims["iss"] == .string(issuer) else { throw K9ORampartReceiptError(.issuer, "the issuer is not the expected one") }
        var expectedProject = options.projectId
        if expectedProject == nil, let c = carriedProjectId, !c.isEmpty { expectedProject = c }
        guard let expectedProject else {
            throw K9ORampartReceiptError(.projectUnknown, "no project id to compare: pass the classify result or options.projectId")
        }
        guard claims["project_id"] == .string(expectedProject) else {
            throw K9ORampartReceiptError(.project, "the receipt names a different project")
        }
        guard case .number(let iat)? = claims["iat"], case .number(let exp)? = claims["exp"], iat.isFinite, exp.isFinite else {
            throw K9ORampartReceiptError(.malformed, "iat and exp must be numbers")
        }
        let nowSec = options.now().timeIntervalSince1970
        if nowSec > exp + options.clockSkewSeconds { throw K9ORampartReceiptError(.expired, "the receipt has expired") }
        if nowSec < iat - options.clockSkewSeconds {
            throw K9ORampartReceiptError(.notYetValid, "the receipt was issued in the future")
        }

        // 5. The receipt must attest this exact input.
        let digest: String
        do {
            digest = k9oSha256Hex(Data(try K9OJcs.canonicalize(input).utf8))
        } catch {
            throw K9ORampartReceiptError(.inputHash, "the input cannot be canonicalised: \((error as? K9OJcsError)?.message ?? "unknown")")
        }
        guard case .string(let attested)? = claims["input_sha256"] else {
            throw K9ORampartReceiptError(.malformed, "input_sha256 is missing")
        }
        guard attested == digest else { throw K9ORampartReceiptError(.inputHash, "the receipt does not attest this input") }

        // 6. The verdict comes from the verified claims.
        guard case .string(let cs)? = claims["classification"], let classification = K9ORampartClassification(rawValue: cs) else {
            throw K9ORampartReceiptError(.malformed, "unknown classification")
        }
        guard let risk = Self.isBp(claims["risk_bp"]), let confidence = Self.isBp(claims["confidence_bp"]) else {
            throw K9ORampartReceiptError(.malformed, "risk_bp and confidence_bp must be integers 0 to 10000")
        }
        guard case .array(let rawCats)? = claims["categories"] else {
            throw K9ORampartReceiptError(.malformed, "categories must be a list of strings")
        }
        var cats: [String] = []
        for c in rawCats {
            guard case .string(let s) = c else { throw K9ORampartReceiptError(.malformed, "categories must be a list of strings") }
            cats.append(s)
        }
        guard case .string(let calibration)? = claims["calibration_version"] else {
            throw K9ORampartReceiptError(.malformed, "calibration_version is missing")
        }
        // `windows` is how many windows were scored; a missing claim reads as 1. Other unknown claims are ignored.
        var windows = 1
        if let w = claims["windows"] {
            guard case .number(let n) = w, n.isFinite, n == n.rounded(), n >= 1, n <= 9007199254740991 else {
                throw K9ORampartReceiptError(.malformed, "windows must be a positive integer")
            }
            windows = Int(n)
        }
        return K9ORampartVerified(classification: classification, riskScore: risk, confidence: confidence, categories: cats,
                                  calibrationVersion: calibration, projectId: expectedProject, inputSha256: digest,
                                  issuer: issuer, issuedAt: iat, expiresAt: exp, kid: kid, windows: windows)
    }
}
