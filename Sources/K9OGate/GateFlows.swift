import Foundation

// The end-user flows beyond sign-in: passkeys, authenticator-app second factors, password reset, invitations and
// session checks. They are the wire layer: the passkey calls carry WebAuthn options and credentials between your app
// and the gateway and do not call the platform's passkey API (AuthenticationServices). Hand the options `begin`
// returned to that API and pass the credential it makes, in its JSON form, to `finish`.

// MARK: - Request bodies (internal; match the gateway OpenAPI)

private struct PasskeyRegisterFinishBody: Encodable {
    let response: [String: K9OJSON]
    let label: String?
}
private struct PasskeySignInBeginBody: Encodable { let email: String? }
private struct PasskeySignInFinishBody: Encodable { let response: [String: K9OJSON] }
private struct TotpEnrollBody: Encodable { let label: String? }
private struct TotpConfirmBody: Encodable {
    let factorId: String
    let code: String
    let currentCode: String?
}
private struct MfaMethodDeleteBody: Encodable { let code: String }
private struct PasswordResetRequestBody: Encodable { let email: String }
private struct PasswordResetRedeemBody: Encodable {
    let token: String
    let newPassword: String
}
private struct InvitationRedeemBody: Encodable {
    let token: String
    let password: String
    let displayName: String?
}
private struct VerifySessionBody: Encodable { let token: String }

// MARK: - Namespaces

extension GateClient {
    /// Passkeys (WebAuthn): `gate.passkeys.register.begin` and `finish`, `gate.passkeys.signIn.begin` and `finish`.
    public var passkeys: GatePasskeys { GatePasskeys(client: client) }

    /// Second factors for the signed-in end user: `gate.mfa.totp.enroll` and `confirm`, `gate.mfa.methods.list` and `delete`.
    public var mfa: GateMfa { GateMfa(client: client) }

    /// Password reset by email: `gate.passwordReset.request` and `redeem`.
    public var passwordReset: GatePasswordReset { GatePasswordReset(client: client) }

    /// Invitations: `gate.invitations.redeem`.
    public var invitations: GateInvitations { GateInvitations(client: client) }

    /// Check an end user's access token from your backend.
    ///
    /// The call is authenticated with `bearerToken` (the credential your backend holds); the end user's access token
    /// to check goes in `token`. A token that is invalid, expired, issued for another project or belongs to an end
    /// user who is no longer active is an answer with `valid` false and a `reason`, not an error.
    ///
    /// Mirrors: `POST /@<projectSlug>/gate/verify-session`.
    public func verifySession(token: String, bearerToken: String) async throws -> K9OSessionVerification {
        try await client.send(
            path: "verify-session", body: VerifySessionBody(token: token), bearerToken: bearerToken,
            responseType: K9OSessionVerification.self
        )
    }
}

/// `gate.passkeys`. Routes: `POST /@<projectSlug>/gate/passkeys/{register,signin}/{begin,finish}`.
public struct GatePasskeys: Sendable {
    let client: GateAuthClient

    /// Adding a passkey to the signed-in end user. Both calls need the end user's access token as `bearerToken`.
    public var register: GatePasskeyRegistration { GatePasskeyRegistration(client: client) }

    /// Signing in with a passkey. Neither call sends a credential.
    public var signIn: GatePasskeySignIn { GatePasskeySignIn(client: client) }
}

/// `gate.passkeys.register`.
public struct GatePasskeyRegistration: Sendable {
    let client: GateAuthClient

    /// Start adding a passkey. The answer is the registration options (`challenge` and the rest); the challenge is
    /// single-use and short-lived. Hand `json` to the platform's passkey API.
    ///
    /// Mirrors: `POST /@<projectSlug>/gate/passkeys/register/begin`.
    public func begin(bearerToken: String) async throws -> K9OPasskeyOptions {
        try await client.send(path: "passkeys/register/begin", bearerToken: bearerToken, responseType: K9OPasskeyOptions.self)
    }

    /// Finish adding a passkey with the credential the authenticator made from `begin`'s options, in its JSON form
    /// (`RegistrationResponseJSON`). `label` names the passkey (1 to 256 characters).
    /// A challenge that is invalid, expired or used, or a credential that does not verify, throws `K9OGateError.unknown`
    /// with `statusCode` 400 and `code` `K9O_INVALID_FIELD_VALUE`.
    ///
    /// Mirrors: `POST /@<projectSlug>/gate/passkeys/register/finish`.
    public func finish(response: [String: K9OJSON], label: String? = nil, bearerToken: String) async throws -> K9OPasskeyRegistration {
        try await client.send(
            path: "passkeys/register/finish", body: PasskeyRegisterFinishBody(response: response, label: label),
            bearerToken: bearerToken, responseType: K9OPasskeyRegistration.self
        )
    }
}

/// `gate.passkeys.signIn`.
public struct GatePasskeySignIn: Sendable {
    let client: GateAuthClient

    /// Start a passkey sign-in. The answer is the authentication options (`challenge` and the rest). Pass `email` to
    /// name the account, or omit it to let the authenticator offer the passkeys it holds for this site.
    ///
    /// Mirrors: `POST /@<projectSlug>/gate/passkeys/signin/begin`.
    public func begin(email: String? = nil) async throws -> K9OPasskeyOptions {
        try await client.send(path: "passkeys/signin/begin", body: PasskeySignInBeginBody(email: email), responseType: K9OPasskeyOptions.self)
    }

    /// Finish a passkey sign-in with the assertion the authenticator made from `begin`'s options, in its JSON form
    /// (`AuthenticationResponseJSON`). The answer is `session`; the client does not store its refresh token.
    /// A challenge that is invalid, expired or used, an unknown passkey, or an assertion that does not verify throws
    /// `K9OGateError.unknown` with `statusCode` 400 and `code` `K9O_INVALID_FIELD_VALUE`.
    ///
    /// Mirrors: `POST /@<projectSlug>/gate/passkeys/signin/finish`.
    public func finish(response: [String: K9OJSON]) async throws -> K9OPasskeySignIn {
        try await client.send(
            path: "passkeys/signin/finish", body: PasskeySignInFinishBody(response: response), responseType: K9OPasskeySignIn.self
        )
    }
}

/// `gate.mfa`.
public struct GateMfa: Sendable {
    let client: GateAuthClient

    /// Authenticator apps. Both calls need the end user's access token as `bearerToken`.
    public var totp: GateTotp { GateTotp(client: client) }

    /// The factors on the account. Both calls need the end user's access token as `bearerToken`.
    public var methods: GateMfaMethods { GateMfaMethods(client: client) }
}

/// `gate.mfa.methods`. Routes: `GET /@<projectSlug>/gate/mfa/methods` and
/// `DELETE /@<projectSlug>/gate/mfa/methods/<methodId>`.
public struct GateMfaMethods: Sendable {
    let client: GateAuthClient

    /// The signed-in end user's second factors, oldest first: authenticator apps (`totp`, confirmed or not) and
    /// passkeys (`webauthn`).
    ///
    /// Mirrors: `GET /@<projectSlug>/gate/mfa/methods`.
    public func list(bearerToken: String) async throws -> K9OMfaMethodList {
        try await client.send(method: "GET", path: "mfa/methods", bearerToken: bearerToken, responseType: K9OMfaMethodList.self)
    }

    /// Remove a second factor by its `id`. Removing a confirmed authenticator needs its current code in `code`;
    /// without it the call throws `K9OGateError.unknown` with `code` `K9O_MFA_REQUIRED`. A wrong or expired code
    /// throws `K9OGateError.invalidCredentials` (401), and too many wrong codes throws `K9OGateError.rateLimited`.
    /// An unconfirmed authenticator and a passkey need no code. The answer is `deleted` `false` when the end user has no
    /// such method.
    ///
    /// Mirrors: `DELETE /@<projectSlug>/gate/mfa/methods/<methodId>`.
    public func delete(methodId: String, code: String? = nil, bearerToken: String) async throws -> K9OMfaMethodDeletion {
        try await client.send(
            method: "DELETE", path: "mfa/methods/\(methodId)", body: code.map { MfaMethodDeleteBody(code: $0) },
            bearerToken: bearerToken, responseType: K9OMfaMethodDeletion.self
        )
    }
}

/// `gate.mfa.totp`. Routes: `POST /@<projectSlug>/gate/mfa/totp/{enroll,confirm}`.
public struct GateTotp: Sendable {
    let client: GateAuthClient

    /// Start setting up an authenticator app. The answer is the factor's `id`, the base32 `secret` and the
    /// `otpauth://` `uri` for a QR code. The secret is shown only in this answer, and the factor does nothing until
    /// `confirm` succeeds. `label` names it (1 to 256 characters, default `TOTP`).
    ///
    /// Mirrors: `POST /@<projectSlug>/gate/mfa/totp/enroll`.
    public func enroll(label: String? = nil, bearerToken: String) async throws -> K9OTotpEnrollment {
        try await client.send(
            path: "mfa/totp/enroll", body: TotpEnrollBody(label: label), bearerToken: bearerToken,
            responseType: K9OTotpEnrollment.self
        )
    }

    /// Finish setting up an authenticator app with its first code. To add a second authenticator, also pass
    /// `currentCode` from one already confirmed; without it the call throws `K9OGateError.unknown` with `code`
    /// `K9O_MFA_REQUIRED`. A wrong or expired code throws `K9OGateError.invalidCredentials` (401). When this is the
    /// person's first confirmed authenticator, their other sessions end and the answer carries a new `session`.
    ///
    /// Mirrors: `POST /@<projectSlug>/gate/mfa/totp/confirm`.
    public func confirm(factorId: String, code: String, currentCode: String? = nil, bearerToken: String) async throws -> K9OTotpConfirmation {
        try await client.send(
            path: "mfa/totp/confirm", body: TotpConfirmBody(factorId: factorId, code: code, currentCode: currentCode),
            bearerToken: bearerToken, responseType: K9OTotpConfirmation.self
        )
    }
}

/// `gate.passwordReset`. Routes: `POST /@<projectSlug>/gate/password-reset/{request,redeem}`. Neither call sends a
/// credential.
public struct GatePasswordReset: Sendable {
    let client: GateAuthClient

    /// Email a reset link to the address. The answer is the same whether or not the address has an account. The token
    /// is valid for one hour and works once. A deployment with no mail relay answers 503 `K9O_EMAIL_NOT_CONFIGURED`.
    ///
    /// Asks the project which region holds the email first (`POST /@<projectSlug>/gate/locate`, email only), like
    /// `signIn`; a 429 or 503 from that step is thrown as `K9OGateError.rateLimited` or `K9OGateError.regionUnavailable`.
    ///
    /// Mirrors: `POST /@<projectSlug>/gate/password-reset/request`.
    public func request(email: String) async throws -> K9OPasswordResetRequest {
        let origin = try await client.locate(email: email)
        return try await client.send(
            path: "password-reset/request", body: PasswordResetRequestBody(email: email),
            responseType: K9OPasswordResetRequest.self, origin: origin
        )
    }

    /// Set a new password with the token from the email. The answer carries a `session`, or, when the account has a
    /// confirmed authenticator, an `mfa` challenge and no session. A wrong, expired or used token, or a password the
    /// project refuses, throws `K9OGateError.unknown` with `statusCode` 400.
    ///
    /// Mirrors: `POST /@<projectSlug>/gate/password-reset/redeem`.
    public func redeem(token: String, newPassword: String) async throws -> K9OPasswordResetRedemption {
        try await client.send(
            path: "password-reset/redeem", body: PasswordResetRedeemBody(token: token, newPassword: newPassword),
            responseType: K9OPasswordResetRedemption.self
        )
    }
}

/// `gate.invitations`. An operator creates an invitation from the Console or the API; the invited person redeems it here.
public struct GateInvitations: Sendable {
    let client: GateAuthClient

    /// Accept an invitation. The token from the invitation and a password create the end user. The answer is the
    /// `user` (`id`, `email`) and a `session`; the client does not store its refresh token. A wrong, expired or used
    /// token, or a password the project refuses, throws `K9OGateError.unknown` with `statusCode` 400.
    ///
    /// Mirrors: `POST /@<projectSlug>/gate/invitations/redeem`.
    public func redeem(token: String, password: String, displayName: String? = nil) async throws -> K9OInvitationRedemption {
        try await client.send(
            path: "invitations/redeem", body: InvitationRedeemBody(token: token, password: password, displayName: displayName),
            responseType: K9OInvitationRedemption.self
        )
    }
}
