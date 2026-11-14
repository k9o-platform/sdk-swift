# K9OGate

Official Swift SDK for [Kilimanjaro](#136-about-kilimanjaro) Gate.
Sign users in from your Swift app with Gate: sign in, refresh the session and sign out, with the refresh token kept in the platform's secure storage.
A Gate token also scopes each data request to the signed-in user.

## Contents

**A. Get started**

1. [Links](#1-links)
2. [Install](#2-install)
3. [Choose the right package](#3-choose-the-right-package)
4. [Requirements](#4-requirements)
5. [Quick start](#5-quick-start)

**B. Sessions**

6. [Refresh and sign out](#6-refresh-and-sign-out)
7. [Session lifetime](#7-session-lifetime)
8. [Keychain storage](#8-keychain-storage)
9. [Passkeys, authenticator apps, password reset and invitations](#9-passkeys-authenticator-apps-password-reset-and-invitations)

**C. Use the token**

10. [Read token claims](#10-read-token-claims)
11. [K9OCore](#11-k9ocore)

**D. Troubleshoot**

12. [Handle errors](#12-handle-errors)

**E. Reference**

13. [Appendix](#13-appendix)
    - 13.1 [Client options](#131-client-options)
    - 13.2 [Error fields](#132-error-fields)
    - 13.3 [Methods](#133-methods)
    - 13.4 [Types](#134-types)
    - 13.5 [Related packages](#135-related-packages)
    - 13.6 [About Kilimanjaro](#136-about-kilimanjaro)
14. [License](#14-license)

## A. Get started

### 1. Links

- Website: <https://kilimanjaro.dev>
- Documentation / Developer Hub: <https://docs.kilimanjaro.dev>
- Open source
  - Platform: <https://github.com/k9o-platform>
  - Community: <https://github.com/k9o-community>

### 2. Install

Add the package with Swift Package Manager.

```swift
dependencies: [
    .package(url: "https://github.com/k9o-platform/sdk-swift.git", from: "1.5.2"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "K9OGate", package: "sdk-swift"),
        ]
    ),
]
```

The package has two libraries, `K9OGate` and `K9OCore`. Add only the ones you use.

In Xcode, choose File > Add Package Dependencies and enter the same URL.

### 3. Choose the right package

| Package | Use it when you are… | Registry | Source |
| --- | --- | --- | --- |
| `K9OCore` | Calling the platform from an iOS or macOS app as a signed-in user. | Swift Package Manager (resolves from the repository) | [sdk-swift](https://github.com/k9o-platform/sdk-swift) |
| `K9OGate` | Signing users in: sign in, refresh and sign out, with the refresh token kept in the Keychain. | Swift Package Manager (resolves from the repository) | [sdk-swift](https://github.com/k9o-platform/sdk-swift) |
| `K9OKibo` | Encrypting and decrypting on the device with a key in your own KMS. | Swift Package Manager (resolves from the repository) | [sdk-kibo-swift](https://github.com/k9o-platform/sdk-kibo-swift) |
| `K9OBarbican` | Checking model input and redacting model output on the device. | Swift Package Manager (resolves from the repository) | [sdk-barbican-swift](https://github.com/k9o-platform/sdk-barbican-swift) |

### 4. Requirements

- iOS 15 or later, or macOS 12 or later
- Swift 5.9 or later
- No third-party dependencies

### 5. Quick start

The examples sign in an end user of a project called `tasks-app`, which belongs to the organization `acme`.

```swift
import K9OGate

let orgURL = URL(string: "https://acme.api.k9o.io")!
let gate = GateClient(orgBaseURL: orgURL, projectSlug: "tasks-app")

let result = try await gate.signIn(email: "alice@example.com", password: "a-strong-password")

print("Signed in as \(result.user.email) (\(result.user.id))")
print("Access token expires at \(result.session.expiresAt)")
```

```text
Signed in as alice@example.com (eu_...)
Access token expires at 2026-01-01T12:00:00Z
```

`orgBaseURL` is the short address of your organization. On the first call the client asks it, without any credential, which regional host serves you, then sends every call there, so the email and password only ever go to your region. You can also pass the regional address (`https://acme.api-de01.k9o.io`) and skip that step. `signIn` saves the refresh token in the Keychain for you.

Instead of the address you can pass your organization slug: `try GateClient(orgSlug: "acme", projectSlug: "tasks-app")` uses `https://acme.api.k9o.io`. A full organization address or a custom domain is used as given, and `orgSlug` does not change it. With neither `orgBaseURL` nor `orgSlug`, construction throws `K9OGateConfigError.invalidBaseURL` (code `K9O_INVALID_BASE_URL`, context `["field": "baseUrl"]`). A malformed slug throws `K9OGateConfigError.invalidFieldValue` (code `K9O_INVALID_FIELD_VALUE`, context `["field": "orgSlug", "slug": <the value>]`). The error exposes `code`, `message` and `context`.

`signIn` first asks the project which region holds the email: one extra request that carries only the email. The SDK sends the password only to a region host of your own organization and apex, and otherwise to the base URL. Nothing from that step is cached, apart from a note of which region issued the session so that refresh and sign-out go to the same place. A `429` or `503` from that step is thrown as the usual `K9OGateError` (`.rateLimited` or `.regionUnavailable`) and is safe to retry. If the project's locate step answers 404, the client uses the base address.

See all [client options](#131-client-options).

[↑ Back to Contents](#contents)

## B. Sessions

### 6. Refresh and sign out

With no argument, `refreshToken()` uses the stored refresh token and returns a new access token, the next refresh token and the access token's expiry.
Each refresh replaces the refresh token: the one you sent stops working. The client saves the new one to the Keychain before `refreshToken()` returns, and it refreshes one at a time, so calls made together share one request and a token is never sent twice.

```swift
let refreshed = try await gate.refreshToken()

print("New access token expires at \(refreshed.expiresAt)")
```

```text
New access token expires at 2026-01-01T13:00:00Z
```

`signOut()` revokes the session and deletes the stored refresh token. It returns `true` when a live session was revoked.

```swift
let revoked = try await gate.signOut()

print("Revoked: \(revoked)")
```

```text
Revoked: true
```

See all [methods](#133-methods).

### 7. Session lifetime

Three settings control how long an end user's session lasts. A project administrator sets them for the project in the Console, under the project's Gate settings, Sessions. The values below are the defaults, and each has a range:

| Setting | Default | Range |
|---|---|---|
| Access token lifetime | 30 minutes | 5 to 60 minutes |
| Sign out after inactivity | 30 days | 1 hour to 90 days |
| Maximum session length | 90 days | 1 hour to 365 days |

Refresh is where the limits are checked. Inactivity counts from the last successful refresh, so it is measured to within one access-token lifetime. A refresh token never outlasts either limit. A changed setting applies to existing sessions at their next refresh, and a shorter maximum ends the sessions already past it.

- **A refresh token works once.** Each refresh answers a new refresh token and the old one stops working. Sending an old one again counts as a replay: the gateway ends the session, and `refreshToken()` throws `.sessionEnded(reason: .replay, requestId:)`. The new token then fails the same way, with `.revoked`. The client deletes the stored token on any of these, and the user must sign in again.
- **A session that has ended says why.** `sessionEndReason` on the error is `.inactive` (past the sign-out-after-inactivity limit), `.maxLength` (past the maximum session length), `.revoked` (signed out, ended by a password reset, or ended by `revokeAllSessions`) or `.replay` (see above). It is kept when `errors` is `.redacted`. A token the gateway does not know, or one for a locked user, throws `.invalidCredentials` and also deletes the stored token.
- **Keep your own refresh token only if you must.** If your app keeps a copy outside the Keychain, replace it with the `refreshToken` that each refresh returns, and never refresh from two places at once.
- **`signOut` ends this device's session.** It revokes the session that the stored refresh token belongs to. The same user's sessions on other devices stay valid.
- **`revokeAllSessions(accessToken:)` ends every session of the user.** Pass the access token that `signIn` or `refreshToken` returned, not a refresh token. It ends the user's sessions on every device, this one included, deletes the stored refresh token and returns how many sessions ended. Each ended session's next refresh is refused with `K9O_SESSION_EXPIRED`; the error is `.sessionEnded(reason: .revoked, ...)`. An operator's token is refused with `K9O_TRUST_ZONE_VIOLATION` (403), and a token issued for another project with `K9O_PROJECT_SCOPE_MISMATCH` (403). The stored token is left as it was when the call fails. Access tokens already issued keep working until they expire, so drop yours too.
- **An access token outlives sign-out.** One that was already issued keeps working until it expires, up to the access token lifetime you set, because it carries no session id and Gate keeps no list of revoked access tokens. The exception is a user who is no longer active: a locked or erased user's access tokens are refused at once.
- **A session that has passed a limit is refused.** The refresh answers 401 `K9O_SESSION_EXPIRED`, and `context.reason` is `inactive`, `max_length`, `revoked` (after sign-out) or `replay` (a used refresh token sent again). Send the user through sign-in again.
- **A password reset ends every existing session of that user.** The session the reset itself opens stays. Erasing a user locks them and revokes every session; an administrator's reset of a user's second factor also revokes every session.

### 8. Keychain storage

The refresh token is saved with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
It is not synced to iCloud or moved to a new device.

To manage tokens yourself, turn storage off with `tokenStore: nil`.
Then pass the refresh token to `refreshToken(refreshToken:)` and `signOut(refreshToken:)`.
The `signIn` result holds it in `result.session.refreshToken`.

```swift
let gate = GateClient(orgBaseURL: orgURL, projectSlug: "tasks-app", tokenStore: nil)
```

### 9. Passkeys, authenticator apps, password reset and invitations

These calls are the wire layer for the end-user flows beyond password sign-in. The passkey calls carry WebAuthn options and credentials between your app and the gateway. They do not call the platform's passkey API (AuthenticationServices): hand the options `begin` returns to that API, and pass the credential it makes, in its JSON form, to `finish`.

Calls that act for a signed-in end user take that end user's access token as `bearerToken`. Calls that start a sign-in or redeem a token send no credential.

| Call | Needs | Returns |
|---|---|---|
| `passkeys.register.begin(bearerToken:)` | The end user's access token | `K9OPasskeyOptions` |
| `passkeys.register.finish(response:label:bearerToken:)` | The end user's access token and the credential from the authenticator | `K9OPasskeyRegistration` |
| `passkeys.signIn.begin(email:)` | Nothing; `email` is optional | `K9OPasskeyOptions` |
| `passkeys.signIn.finish(response:)` | The assertion from the authenticator | `K9OPasskeySignIn` with a `session` |
| `mfa.totp.enroll(label:bearerToken:)` | The end user's access token | `K9OTotpEnrollment` with the `secret` and an `otpauth://` `uri` |
| `mfa.totp.confirm(factorId:code:currentCode:bearerToken:)` | The end user's access token and a current code | `K9OTotpConfirmation` |
| `mfa.methods.list(bearerToken:)` | The end user's access token | `K9OMfaMethodList` (`methods`, each with `id`, `type`, `label`, `verifiedAt`, `createdAt`) |
| `mfa.methods.delete(methodId:code:bearerToken:)` | The end user's access token; the authenticator's current code for a confirmed authenticator | `K9OMfaMethodDeletion` (`deleted`) |
| `passwordReset.request(email:)` | Nothing | `K9OPasswordResetRequest` |
| `passwordReset.redeem(token:newPassword:)` | The token from the email | `K9OPasswordResetRedemption` |
| `invitations.redeem(token:password:displayName:)` | The token from the invitation | `K9OInvitationRedemption` |
| `verifySession(token:bearerToken:)` | A credential for your backend, and the end user's access token to check | `K9OSessionVerification` |

```swift
let options = try await gate.passkeys.signIn.begin(email: "user@example.test")
// Give options.json to the platform's passkey API, which returns an assertion; convert it to its JSON form.
let assertion: [String: K9OJSON] = try await makeAssertion(from: options.json) // your code
let result = try await gate.passkeys.signIn.finish(response: assertion)
```

- A passkey challenge is single-use and short-lived. A challenge that is invalid, expired or used, or a credential that does not verify, throws `K9OGateError.unknown` with `statusCode` 400 and `code` `K9O_INVALID_FIELD_VALUE`.
- `mfa.totp.enroll` shows the `secret` and the `uri` once. The authenticator does nothing until `confirm` succeeds. To add a second authenticator, pass `currentCode` from one already confirmed. When this is the person's first confirmed authenticator, their other sessions end and the answer carries a new `session`. A wrong or expired code throws `K9OGateError.invalidCredentials`.
- `mfa.methods.list` returns authenticator apps (`totp`, confirmed or not) and passkeys (`webauthn`), oldest first. `mfa.methods.delete` needs `code`, the authenticator's current code, to remove a confirmed authenticator; without it the call throws `K9OGateError.unknown` with `code` `K9O_MFA_REQUIRED`. A wrong or expired code throws `K9OGateError.invalidCredentials`. An unconfirmed authenticator and a passkey need no code, and `deleted` is `false` when the end user has no such method.
- `passwordReset.request` answers the same whether or not the address has an account, and asks the project which region holds the email first, like `signIn`. The token works once and expires after one hour. A deployment with no mail relay answers 503 `K9O_EMAIL_NOT_CONFIGURED`. `passwordReset.redeem` returns a `session`, or an `mfa` challenge and no session when the account has a confirmed authenticator.
- A token that `verifySession` refuses (invalid, expired, for another project, or for an end user who is no longer active) is an answer with `valid` `false` and a `reason`, not an error.
- None of these calls stores a refresh token. Keep the `session` they return the way you keep one from `signIn`.

[↑ Back to Contents](#contents)

## C. Use the token

### 10. Read token claims

`K9OAccessToken.decode` reads an access token on the device. It does not verify the signature, so do not use it for security decisions.

Custom claims are flat keys of the form `ext.<namespace>.<name>`. `customClaim(namespace:name:)` reads one of them.

```swift
if let token = K9OAccessToken.decode(result.session.accessToken) {
    let role = token.customClaim(namespace: "partners", name: "partner_role") as? String
    print("Partner role: \(role ?? "none")")
}
```

```text
Partner role: extension_org_admin
```

`customClaims` returns every `ext.` claim, keyed by its full name, for example `ext.partners.partner_role`.

### 11. K9OCore

The second library, `K9OCore`, is a project-plane client with two calls: `ai.embed` and `ai.generate`.

```swift
import K9OCore

let core = K9OCoreClient(baseURL: orgURL, projectSlug: "tasks-app", accessToken: accessToken)
let response = try await core.ai.embed(input: .one("Write the README"))
let vectors = response.data.embeddings
```

The platform rejects an end user's token for this call. Use the token of a project member or an extension.

See [related packages](#135-related-packages).

[↑ Back to Contents](#contents)

## D. Troubleshoot

### 12. Handle errors

Every call throws `K9OGateError`. Catch the cases you care about.

```swift
do {
    _ = try await gate.signIn(email: "alice@example.com", password: "wrong-password")
} catch K9OGateError.invalidCredentials {
    print("Wrong email or password.")
} catch K9OGateError.network(let error) {
    print("Network problem: \(error.localizedDescription)")
} catch {
    print("Sign-in failed: \(error.localizedDescription)")
}
```

```text
Wrong email or password.
```

See all [error cases](#132-error-fields).

[↑ Back to Contents](#contents)

## E. Reference

### 13. Appendix

- [Client options](#131-client-options)
- [Error fields](#132-error-fields)
- [Methods](#133-methods)
- [Types](#134-types)
- [Related packages](#135-related-packages)
- [About Kilimanjaro](#136-about-kilimanjaro)

#### 13.1 Client options

`GateClient(orgBaseURL:projectSlug:tokenStore:urlSession:probeTransport:)`, or `try GateClient(orgBaseURL:orgSlug:projectSlug:tokenStore:urlSession:probeTransport:)` when you pass `orgSlug`

| Option | Meaning |
|---|---|
| `orgBaseURL` | Optional when `orgSlug` is given. Your organization's API address, short (`https://acme.api.k9o.io`) or regional (`https://acme.api-de01.k9o.io`). The short address is resolved once to your region with a request that carries no credentials; every call then goes to the regional host. A regional address is used as given |
| `orgSlug` | Your organization's slug, e.g. `acme`. `orgBaseURL` is optional when you give it, and the client uses `https://acme.api.k9o.io`. It is only used to build the address: a full organization address or a custom domain is used as given |
| `projectSlug` | The project's slug |
| `tokenStore` | A `KeychainTokenStore`; default is Keychain storage, `nil` turns storage off |
| `urlSession` | The `URLSession` to use; default is `URLSession.shared` |
| `probeTransport` | A custom way to send the credential-free region request; default is a session with the configuration of `urlSession` that does not follow redirects |
| `errors` | `.full` (default) keeps the gateway's code, recommendation and body on an error. `.redacted` drops them for an unknown code, and gateway text otherwise; see [Error fields](#132-error-fields) |

`KeychainTokenStore(service:account:)` lets you choose the Keychain service and account names.

#### 13.2 Error fields

An app shows `publicMessage` to its users: a fixed sentence chosen by status class, which never contains the gateway's text. `code`, `recommendation`, `statusCode` and `retryAfterSec` are for logs and for your own handling, and `errorDescription` is for logs too. A `K9O_*` code this SDK does not name is kept in `code`, so a configuration fault is not read as a transient one. Set `errors: .redacted` on `GateClient` to drop an unknown code, its body and its recommendation; the status, `publicMessage` and any retry wait stay.

| Accessor | Meaning |
|---|---|
| `publicMessage` | The sentence an app shows its users. Same wording in every Gate client |
| `code` | The gateway code with its `K9O_` prefix, e.g. `K9O_MAGIC_LINK_REDIRECT_NOT_CONFIGURED`. Nil for a transport or decoding failure |
| `recommendation` | The gateway's next step as text, for logs |
| `statusCode` | The HTTP status, or nil for a transport or decoding failure |
| `retryAfterSec` | Seconds the gateway asks you to wait, when it sent one |
| `requestId` | The request id, from the `x-k9o-request-id` response header, for support and logs. Nil when the response has no such header, and for a transport or decoding failure. Kept in redacted mode |
| `errors` option | `.full` (default) or `.redacted`, set on `GateClient(...)` |

The typed cases and `.unknown` carry the same `requestId` as their associated value, read from the `x-k9o-request-id` header.

| Case | Meaning |
|---|---|
| `.invalidCredentials(requestId:)` | The email or password did not match |
| `.rateLimited(statusCode:body:requestId:)` | Too many sign-in attempts; safe to retry |
| `.regionUnavailable(statusCode:body:requestId:)` | The region that holds the email is unavailable; safe to retry |
| `.unauthenticated(requestId:)` | The session is missing, expired or revoked, or no refresh token is stored |
| `.sessionEnded(reason:requestId:)` | The gateway ended the session, and `reason` (`.inactive`, `.maxLength`, `.revoked` or `.replay`) says why; the user must sign in again |
| `.forbidden(requestId:)` | The session may not perform this operation |
| `.network(Error)` | The request failed in transit |
| `.decoding(Error)` | The response was not in the expected shape |
| `.unknown(statusCode:body:requestId:)` | Any other non-2xx response, with the status, raw body and request id |

#### 13.3 Methods

| Method | Meaning |
|---|---|
| `signIn(email:password:)` | Sign in; returns `K9OAuthResult` |
| `refreshToken(refreshToken:)` | Get a new access token; returns `K9ORefreshResult` |
| `signOut(refreshToken:)` | End the session; returns `true` when a live session was revoked |
| `revokeAllSessions(accessToken:)` | End every session of the user, on every device, and delete the stored token; returns how many ended |
| `K9OAccessToken.decode(_:)` | Read a token's claims on the device |
| `customClaim(namespace:name:)` | One `ext.<namespace>.<name>` claim, or `nil` |
| `passkeys.register.begin`, `passkeys.register.finish`, `passkeys.signIn.begin`, `passkeys.signIn.finish` | Passkey registration and sign-in (wire layer) |
| `mfa.totp.enroll`, `mfa.totp.confirm` | Set up an authenticator app |
| `mfa.methods.list`, `mfa.methods.delete` | List and remove the end user's second factors |
| `passwordReset.request`, `passwordReset.redeem` | Reset a password by email |
| `invitations.redeem` | Accept an invitation |
| `verifySession(token:bearerToken:)` | Check an end user's access token from your backend |

#### 13.4 Types

| Type | Fields |
|---|---|
| `K9OAuthResult` | `user`, `session` |
| `K9OEndUser` | `id`, `email`, `status`, `createdAt`, `updatedAt`, `lastSigninAt`, `roles`, `groups` |
| `K9OSession` | `accessToken`, `refreshToken`, `expiresAt` |
| `K9ORefreshResult` | `accessToken`, `refreshToken`, `expiresAt` |
| `K9OJSON` | A JSON value: `null`, `bool`, `number`, `string`, `array`, `object` |
| `K9OPasskeyOptions` | `challenge`, `json` |
| `K9OPasskeyRegistration` | `passkey` (`id`, `credentialId`) |
| `K9OPasskeySignIn` | `session` |
| `K9OTotpEnrollment` | `factor` (`id`, `secret`, `uri`) |
| `K9OTotpConfirmation` | `factor` (`id`, `verifiedAt`), `session` |
| `K9OPasswordResetRequest` | `reset` (`requested`, `expiresAt`), `debugToken` |
| `K9OPasswordResetRedemption` | `redeemed`, `endUserId`, `session`, `mfa` |
| `K9OMfaChallenge` | `required`, `challengeId`, `expiresAt`, `methodsAvailable`, `resident` |
| `K9OInvitationRedemption` | `redeemed`, `user` (`id`, `email`), `session` |
| `K9OSessionVerification` | `valid`, `claims`, `reason` |
| `K9OAccessToken` | `subject`, `issuer`, `expiresAt`, `issuedAt`, `allClaims`, `customClaims` (flat `ext.` keys) |

#### 13.5 Related packages

| Library | What it does |
|---|---|
| `K9OGate` | Sign-in, refresh and sign-out (this page) |
| `K9OCore` | Project-plane client with `ai.embed` and `ai.generate`, in the same Swift package |

#### 13.6 About Kilimanjaro

Kilimanjaro is a modular developer platform for building secure enterprise applications.
You define AI agents, functions and data pipelines on the platform.
The SDKs let you deploy and invoke them, read and write your data, publish to and subscribe to streams, sign users in, and encrypt with keys you hold.

It provides four building blocks:

- **Keep**: AI security and governance. Guardrails and policy for the agents you run.
- **Pulse**: data intelligence and real-time stream processing. Streams, analytics and live feeds.
- **Gate**: customer identity and access management. Sign-in and sessions, and automatic data scoping so a signed-in user reaches only their own data.
- **Kibo**: cryptographic keys and secrets management. Client-side encryption with keys you hold, and a secrets vault.

### 14. License

Apache-2.0 © Formelo Inc. See `LICENSE` and `NOTICE`.

[↑ Back to Contents](#contents)
