import Foundation

// MARK: - JSON value

/// An arbitrary JSON value. The passkey calls carry WebAuthn options and credentials as JSON the SDK does not
/// interpret: pass the options `begin` returned to the platform's passkey API, and the JSON form of what the
/// authenticator made to `finish`.
public enum K9OJSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([K9OJSON])
    case object([String: K9OJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([K9OJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: K9OJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// MARK: - Passkeys

/// WebAuthn options as the gateway returns them (the JSON form of the creation or request options, with the
/// challenge and the ids base64url-encoded). `json` is the whole object; `challenge` is its single-use challenge.
public struct K9OPasskeyOptions: Codable, Sendable, Equatable {
    public let challenge: String
    public let json: [String: K9OJSON]

    public init(from decoder: Decoder) throws {
        let object = try decoder.singleValueContainer().decode([String: K9OJSON].self)
        guard case .string(let challenge)? = object["challenge"] else {
            throw DecodingError.keyNotFound(
                AnyCodingKey("challenge"),
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "challenge is missing")
            )
        }
        self.challenge = challenge
        self.json = object
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(json)
    }
}

/// The passkey `register.finish` stored.
public struct K9OPasskey: Codable, Sendable, Equatable {
    public let id: String
    public let credentialId: String
}

/// Answer of `passkeys.register.finish`.
public struct K9OPasskeyRegistration: Codable, Sendable, Equatable {
    public let passkey: K9OPasskey
}

/// Answer of `passkeys.signIn.finish`.
public struct K9OPasskeySignIn: Codable, Sendable {
    public let session: K9OSession
}

// MARK: - TOTP

/// The authenticator app being set up. `secret` (base32) and `uri` (`otpauth://`, for a QR code) are shown only in
/// the answer to `mfa.totp.enroll`; the factor does nothing until `mfa.totp.confirm` succeeds.
public struct K9OTotpFactorSetup: Codable, Sendable, Equatable {
    public let id: String
    public let secret: String
    public let uri: String
}

/// Answer of `mfa.totp.enroll`.
public struct K9OTotpEnrollment: Codable, Sendable, Equatable {
    public let factor: K9OTotpFactorSetup
}

/// A confirmed authenticator.
public struct K9OTotpFactor: Codable, Sendable, Equatable {
    public let id: String
    /// ISO 8601 instant the factor was confirmed.
    public let verifiedAt: String
}

/// Answer of `mfa.totp.confirm`. When this is the person's first confirmed authenticator, their other sessions are
/// ended and `session` is a new session for this one.
public struct K9OTotpConfirmation: Codable, Sendable {
    public let factor: K9OTotpFactor
    public let session: K9OSession?
}

// MARK: - MFA methods

/// One second factor on the signed-in end user's account. `type` is `totp` or `webauthn`; `verifiedAt` is `nil` while an
/// authenticator is set up but not yet confirmed.
public struct K9OMfaMethod: Codable, Sendable, Equatable {
    public let id: String
    public let type: String
    public let label: String?
    /// ISO 8601 instant the factor was confirmed, or `nil` if it has not been.
    public let verifiedAt: String?
    /// ISO 8601 instant the factor was created.
    public let createdAt: String
}

/// Answer of `mfa.methods.list`, oldest first.
public struct K9OMfaMethodList: Codable, Sendable, Equatable {
    public let methods: [K9OMfaMethod]
}

/// Answer of `mfa.methods.delete`. `deleted` is `false` when the end user has no such method.
public struct K9OMfaMethodDeletion: Codable, Sendable, Equatable {
    public let deleted: Bool
}

// MARK: - Password reset

/// Answer of `passwordReset.request`. It is the same whether or not the address has an account.
public struct K9OPasswordResetRequest: Codable, Sendable, Equatable {
    public struct Reset: Codable, Sendable, Equatable {
        public let requested: Bool
        public let expiresAt: String?
    }
    public let reset: Reset
    /// Only present on a deployment configured to return the token in the response (development).
    public let debugToken: String?
}

/// A sign-in that needs a second step: a confirmed authenticator code, redeemed with the challenge id.
public struct K9OMfaChallenge: Codable, Sendable, Equatable {
    public struct Resident: Codable, Sendable, Equatable {
        public let region: String
        public let origin: String
    }
    public let required: Bool
    public let challengeId: String
    public let expiresAt: String
    public let methodsAvailable: [String]
    public let resident: Resident
}

/// Answer of `passwordReset.redeem`: a `session`, or an `mfa` challenge (and no session) when the account has a
/// confirmed authenticator.
public struct K9OPasswordResetRedemption: Codable, Sendable {
    public let redeemed: Bool
    public let endUserId: String
    public let session: K9OSession?
    public let mfa: K9OMfaChallenge?
}

// MARK: - Invitations

/// Answer of `invitations.redeem`.
public struct K9OInvitationRedemption: Codable, Sendable {
    public struct User: Codable, Sendable, Equatable {
        public let id: String
        public let email: String
    }
    public let redeemed: Bool
    public let user: User
    public let session: K9OSession
}

// MARK: - Verify session

/// Answer of `verifySession`. A refused token is an answer with `valid` false and a `reason`, not an error.
public struct K9OSessionVerification: Codable, Sendable, Equatable {
    public struct Claims: Codable, Sendable, Equatable {
        public let subjectId: String
        public let projectId: String
        public let expiresAt: String
    }
    public let valid: Bool
    /// Set when `valid` is true.
    public let claims: Claims?
    /// Set when `valid` is false.
    public let reason: String?
}

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
