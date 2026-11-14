# K9OGate Swift SDK — Changelog

## 1.5.2

### Changed

- README: Architecture at a glance, illustrations, and the package table lists only the packages for that SDK.

## 1.5.0

### Fixed

- Calls made against the short address (`https://<org>.api.k9o.io`) no longer fail with 400 `K9O_INVALID_REQUEST_SHAPE`, so sign-in, refresh and sign-out work with it. The client learns your region once with a request that carries no credentials, then sends every call to the regional host. A regional address is used as given.

### Added

- The end-user flows beyond password sign-in, as the wire layer: `passkeys.register.begin` and `finish`, `passkeys.signIn.begin` and `finish`, `mfa.totp.enroll` and `confirm`, `mfa.methods.list(bearerToken:)` and `mfa.methods.delete(methodId:code:bearerToken:)`, `passwordReset.request` and `redeem`, `invitations.redeem`, and `verifySession(token:bearerToken:)`. The passkey calls carry WebAuthn options and credentials as `K9OJSON` and do not call the platform's passkey API.
- `orgSlug` on `GateClient`: `try GateClient(orgSlug: "acme", projectSlug: ...)` uses `https://acme.api.k9o.io`, and `orgBaseURL` becomes optional alongside it. A full organization address or a custom domain is used as given. With neither, construction throws `K9OGateConfigError.invalidBaseURL`; a malformed slug throws `K9OGateConfigError.invalidFieldValue`. `K9OGateConfigError` exposes `code` (`K9O_INVALID_BASE_URL` or `K9O_INVALID_FIELD_VALUE`), `message` and `context` (`["field": "baseUrl"]` or `["field": "orgSlug", "slug": ...]`).
- `signIn` first asks the project which region holds the email (one extra request with only the email) and sends the password to that region's host, if it is a region host of your own organization and apex; otherwise to the base URL. If the project's locate step answers 404, the client uses the base address. `refreshToken` and `signOut` go to the region that issued the session.
- `K9OGateError.rateLimited` and `K9OGateError.regionUnavailable`, thrown when that step answers `429` or `503`. Nothing is retried and no password is sent.
- `probeTransport` option on `GateClient` for the region request.
- `K9OGateError` accessors `code` (the `K9O_*` wire code, including codes the SDK does not name), `recommendation`, `retryAfterSec`, `requestId`, `statusCode` and `publicMessage` (a fixed sentence by status class, safe to show to users). `requestId` is the value of the `x-k9o-request-id` response header; the cases that come from a gateway response carry it as an associated value (`requestId: String?`), so `.unauthenticated`, `.forbidden`, `.invalidCredentials`, `.rateLimited`, `.regionUnavailable` and `.unknown` now take a `requestId` payload. This is a source-breaking change to pattern matches on those cases.
- `errors` option on `GateClient`, a `K9OGateErrorMode`: `.full` (default) or `.redacted`, which drops an unknown code, its body and its recommendation, and keeps the status and any retry wait.

## 1.4.0 — 2026-10-26

### Changed

- README description.

## 1.3.0 — 2026-10-26

### Changed

- `refreshToken(refreshToken:)` takes only the refresh token and returns a `K9ORefreshResult` with `accessToken` and `expiresAt`.
- `refreshToken` no longer replaces the stored refresh token. The gateway does not rotate it.
- `signOut(refreshToken:)` returns a `Bool`: `true` when a live session was revoked.
- `customClaims` returns the flat `ext.<namespace>.<name>` keys of the token.
- Response fields are read as the gateway sends them (camelCase).

### Removed

- The `projectHint` argument of `refreshToken`. The gateway rejects it.

### Added

- `K9ORefreshResult`.
- `K9OAccessToken.customClaim(namespace:name:)` reads one custom claim.


## 1.2.0 — 2026-10-25

- The README now introduces the Kilimanjaro building blocks (Keep, Pulse, Gate, Kibo). No change to the public API.

## 1.1.1 — 2026-10-25

- Documentation links corrected: the documentation hub is https://docs.kilimanjaro.dev,
  with the website, platform API and console listed in a Links section.
  Package metadata points at the same places.

## 1.1.0 — 2026-10-25

- Documentation rewritten with runnable examples and expected output; internal cross-references removed from the published sources.
  No change to the public API.

## 1.0.0 — 2026-10-23

First public release. See the README for the full API overview.
