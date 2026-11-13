import Foundation

/// Kilimanjaro Gate Swift SDK
///
/// `GateClient` is the primary entry point. Initialise once per project
/// and call `signIn`, `refreshToken`, and `signOut`.
///
/// Refresh tokens are automatically persisted in the iOS/macOS Keychain
/// by default, and each refresh stores the next one. Pass `tokenStore: nil`
/// to manage token persistence yourself.
///
/// Example:
/// ```swift
/// let gate = GateClient(
///     orgBaseURL: URL(string: "https://acme.api.k9o.io")!,
///     projectSlug: "my-project"
/// )
/// let result = try await gate.signIn(email: "user@example.com", password: "s3cr3t")
/// ```
public struct GateClient: Sendable {
    let client: GateAuthClient
    private let tokenStore: KeychainTokenStore?
    /// Refreshes in flight. A reference, so every copy of this client shares it.
    private let flights = RefreshFlights()

    /// - Parameters:
    ///   - orgBaseURL: The org-scoped API base, short (`https://acme.api.k9o.io`) or regional
    ///     (`https://acme.api-de01.k9o.io`). The short address is resolved once to your region with a request that
    ///     carries no credentials; every call then goes to the regional host. A regional address is used as given.
    ///   - projectSlug: The `@`-addressable project slug (e.g. `my-project`).
    ///   - tokenStore: Keychain token store. Pass `nil` to skip automatic
    ///     refresh-token persistence.
    ///   - urlSession: Override the URLSession (useful in tests).
    ///   - probeTransport: A custom way to send the credential-free region request. By default a session with the
    ///     configuration of `urlSession` that does not follow redirects.
    ///   - errors: How much of a gateway error to keep. `.full` (default) keeps the gateway's code, recommendation and
    ///     body; `.redacted` drops unknown codes and gateway text. See `K9OGateErrorMode`.
    public init(
        orgBaseURL: URL,
        projectSlug: String,
        tokenStore: KeychainTokenStore? = KeychainTokenStore(),
        urlSession: URLSession = .shared,
        probeTransport: GateTransport? = nil,
        errors: K9OGateErrorMode = .full
    ) {
        self.client = GateAuthClient(
            baseURL: orgBaseURL,
            session: urlSession,
            projectSlug: projectSlug,
            probeTransport: probeTransport,
            errorMode: errors
        )
        self.tokenStore = tokenStore
    }

    /// Builds a client from your organization slug, or from a base URL and a slug.
    ///
    /// - Parameters:
    ///   - orgBaseURL: optional when `orgSlug` is given. A full organization address or a custom domain is used as
    ///     given. A platform address (`https://api.k9o.io`) with `orgSlug` becomes `https://<orgSlug>.api.k9o.io`.
    ///   - orgSlug: your organization's slug, e.g. `acme`. With no `orgBaseURL` the client uses
    ///     `https://<orgSlug>.api.k9o.io`.
    /// - Throws: `K9OGateConfigError.invalidBaseURL` when neither is given; `K9OGateConfigError.invalidFieldValue`
    ///   for a malformed slug that would be used.
    public init(
        orgBaseURL: URL? = nil,
        orgSlug: String?,
        projectSlug: String,
        tokenStore: KeychainTokenStore? = KeychainTokenStore(),
        urlSession: URLSession = .shared,
        probeTransport: GateTransport? = nil,
        errors: K9OGateErrorMode = .full
    ) throws {
        self.init(
            orgBaseURL: try gateResolveBaseURL(orgBaseURL, orgSlug: orgSlug),
            projectSlug: projectSlug,
            tokenStore: tokenStore,
            urlSession: urlSession,
            probeTransport: probeTransport,
            errors: errors
        )
    }

    // MARK: - Public API surface

    /// Sign in an existing end-user with email and password.
    ///
    /// Persists the refresh token in the Keychain on success.
    /// Throws `K9OGateError.invalidCredentials` on bad credentials (HTTP 401).
    ///
    /// Asks the project which region holds the email first (`POST /@<projectSlug>/gate/locate`, email only) and
    /// sends the password to that region's host. A 429 or 503 from that step is thrown as
    /// `K9OGateError.rateLimited` or `K9OGateError.regionUnavailable`, and no password is sent.
    ///
    /// Mirrors: `POST /@<projectSlug>/gate/signin`
    public func signIn(email: String, password: String) async throws -> K9OAuthResult {
        let origin = try await client.locate(email: email)
        let result: K9OAuthResult = try await client.post(
            path: "signin",
            body: SignInBody(email: email, password: password),
            responseType: K9OAuthResult.self,
            origin: origin
        )
        SessionOrigins.shared.remember(result.session.refreshToken, origin)
        try await tokenStore?.save(result.session.refreshToken)
        return result
    }

    /// Mint a new access token from the stored (or supplied) refresh token.
    ///
    /// If `refreshToken` is `nil`, loads the token from the Keychain. Each refresh replaces the refresh token: the
    /// result carries the next one, the client stores it before this call returns, and the one you sent stops
    /// working. Refreshes run one at a time: a call made while another is in flight for the same token shares that
    /// answer, so a token is never sent twice (the gateway treats a second use as a replay and ends the session).
    /// The result has no `user`; read the subject from the access token with `K9OAccessToken.decode`.
    ///
    /// When the gateway has ended the session this throws `K9OGateError.sessionEnded` with the reason (`inactive`,
    /// `maxLength`, `revoked` or `replay`), and the stored token is deleted: the user must sign in again.
    /// `K9OGateError.invalidCredentials` (an unknown token or a locked user) deletes it the same way.
    ///
    /// Mirrors: `POST /@<projectSlug>/gate/refresh` with body `{ refreshToken }`.
    public func refreshToken(refreshToken: String? = nil) async throws -> K9ORefreshResult {
        try await flights.run(explicit: refreshToken) { try await self.refreshOnce(explicit: refreshToken) }
    }

    private func refreshOnce(explicit: String?) async throws -> K9ORefreshResult {
        let stored = try await tokenStore?.load()
        guard let token = explicit ?? stored else { throw K9OGateError.unauthenticated(requestId: nil) }
        let origin = await client.origin(for: SessionOrigins.shared.hint(token))
        let result: K9ORefreshResult
        do {
            result = try await client.post(
                path: "refresh",
                body: RefreshTokenBody(refreshToken: token),
                responseType: K9ORefreshResult.self,
                origin: origin
            )
        } catch let error as K9OGateError {
            switch error {
            case .sessionEnded, .invalidCredentials, .unauthenticated:
                if error.statusCode == 401 {
                    SessionOrigins.shared.forget(token)
                    if token == stored { try await tokenStore?.delete() }
                }
            default: break
            }
            throw error
        }
        if !result.refreshToken.isEmpty {
            SessionOrigins.shared.forget(token)
            SessionOrigins.shared.remember(result.refreshToken, origin)
            // Stored before returning, so the next refresh sends the new token.
            if token == stored || explicit == nil { try await tokenStore?.save(result.refreshToken) }
        }
        return result
    }

    /// Sign out the current session. Deletes the Keychain-stored refresh token.
    ///
    /// If `refreshToken` is `nil`, loads the token from the Keychain; with none,
    /// nothing is sent. Returns `true` when the gateway revoked a live session and
    /// `false` when the token was unknown or already revoked (sign-out is
    /// idempotent; the stored token is deleted either way).
    ///
    /// Mirrors: `POST /@<projectSlug>/gate/signout` with body `{ refreshToken }`.
    @discardableResult
    public func signOut(refreshToken: String? = nil) async throws -> Bool {
        // A refresh in flight is about to replace the stored token; sign out the new one.
        if refreshToken == nil { await flights.waitForStored() }
        let token: String
        if let explicit = refreshToken {
            token = explicit
        } else if let stored = try await tokenStore?.load() {
            token = stored
        } else {
            return false // Already signed out; nothing sent.
        }
        let result: SignOutResponse = try await client.post(
            path: "signout",
            body: SignOutBody(refreshToken: token),
            responseType: SignOutResponse.self,
            origin: await client.origin(for: SessionOrigins.shared.hint(token))
        )
        SessionOrigins.shared.forget(token)
        try await tokenStore?.delete()
        return result.revoked
    }

    /// End every live session of this end user, on every device, this one included, and delete the stored refresh token.
    ///
    /// Call it with the end user's `accessToken` (the one `signIn` or `refreshToken` returned), not a refresh token.
    /// Returns how many sessions ended. Each ended session's next refresh is refused with
    /// `K9OGateError.sessionEnded(reason: .revoked, ...)`; access tokens already issued keep working until they expire,
    /// so drop yours too. An operator's token throws `K9OGateError.unknown` with `statusCode` 403 and `code`
    /// `K9O_TRUST_ZONE_VIOLATION`, and a token issued for another project one with `code` `K9O_PROJECT_SCOPE_MISMATCH`;
    /// the stored token is left as it was.
    ///
    /// A refresh in flight finishes first, so it cannot store a token for a session that is about to end.
    ///
    /// Mirrors: `POST /@<projectSlug>/auth/sessions/revoke-all`.
    @discardableResult
    public func revokeAllSessions(accessToken: String) async throws -> Int {
        await flights.waitForStored()
        let stored = try await tokenStore?.load()
        let result: RevokeAllResponse = try await client.postAuthorized(
            path: "sessions/revoke-all",
            bearerToken: accessToken,
            responseType: RevokeAllResponse.self,
            origin: await client.origin(for: stored.flatMap { SessionOrigins.shared.hint($0) })
        )
        if let stored { SessionOrigins.shared.forget(stored) }
        try await tokenStore?.delete()
        return result.revokedCount
    }
}

// MARK: - Internal helpers

/// Keeps one refresh in flight per token (and one for the stored token), so a token is never sent twice. Loading the
/// stored token, sending it and storing the next one are one step: a late caller shares it rather than sending the old
/// token. The work runs in its own task, so a caller that is cancelled does not lose the next token.
private actor RefreshFlights {
    private var stored: Task<K9ORefreshResult, Error>?
    private var byToken: [String: Task<K9ORefreshResult, Error>] = [:]

    func run(
        explicit: String?,
        _ work: @escaping @Sendable () async throws -> K9ORefreshResult
    ) async throws -> K9ORefreshResult {
        let task: Task<K9ORefreshResult, Error>
        if let explicit {
            if let running = byToken[explicit] {
                task = running
            } else {
                task = Task { try await work() }
                byToken[explicit] = task
            }
        } else if let running = stored {
            task = running
        } else {
            task = Task { try await work() }
            stored = task
        }
        defer {
            if let explicit {
                if byToken[explicit] == task { byToken[explicit] = nil }
            } else if stored == task {
                stored = nil
            }
        }
        return try await task.value
    }

    /// Waits for the refresh of the stored token, if one is running. Its failure is not the caller's.
    func waitForStored() async {
        if let running = stored { _ = try? await running.value }
    }
}

private struct SignOutResponse: Decodable { let revoked: Bool }
private struct RevokeAllResponse: Decodable { let revokedCount: Int }
