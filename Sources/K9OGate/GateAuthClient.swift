import Foundation

/// Internal HTTP transport layer for K9OGate.
///
/// Sends JSON requests to the gateway and decodes JSON responses into
/// typed envelopes. All methods are `async throws`; errors are mapped
/// to `K9OGateError` before surfacing to callers.
struct GateAuthClient {
    let baseURL: URL
    let session: URLSession
    let projectSlug: String
    let regions: GateRegionResolver
    let errorMode: K9OGateErrorMode

    init(
        baseURL: URL,
        session: URLSession,
        projectSlug: String,
        probeTransport: GateTransport? = nil,
        errorMode: K9OGateErrorMode = .full
    ) {
        self.baseURL = baseURL
        self.session = session
        self.projectSlug = projectSlug
        self.errorMode = errorMode
        self.regions = GateRegionResolver(
            configured: baseURL,
            probeTransport: probeTransport ?? gateDefaultProbeTransport(for: session)
        )
    }

    /// The gateway's keys are camelCase on the wire; they pass through unchanged.
    private let decoder = JSONDecoder()

    /// Resolve the project-relative path: `<origin>/@<projectSlug>/<area>/<suffix>`, with `area` `gate` unless a route lives elsewhere.
    /// A short org address is resolved once to its regional origin; any other address is used as given.
    private func url(for suffix: String, origin: URL? = nil, area: String = "gate") async -> URL {
        let path = "/@\(projectSlug)/\(area)/\(suffix)"
        let o: URL
        if let origin { o = origin } else { o = await regions.origin() }
        return o.appendingPathComponent(path)
    }

    /// Ask the project which region holds `email` and return the origin the credential goes to: the located origin if it
    /// passes the rule in `Locate.swift`, else the base. A 404 from the door (the project's locate step is off) means the
    /// base. Any other non-2xx answer (429, 503, anything else) is thrown like any other gateway error and nothing is
    /// retried; a 2xx with a malformed body means the base.
    func locate(email: String) async throws -> URL {
        let base = await regions.origin()
        do {
            let answer: LocateAnswer = try await post(
                path: "locate", body: LocateBody(email: email), responseType: LocateAnswer.self, origin: base
            )
            return chooseLocatedOrigin(base: base, region: answer.region, origin: answer.origin)
        } catch K9OGateError.decoding {
            return base
        } catch K9OGateError.unknown(statusCode: 404, _, _) {
            return base
        }
    }

    /// The origin recorded for a session's refresh token, else the base. A hint only: a stale one gets a 401.
    func origin(for hint: URL?) async -> URL {
        if let hint { return hint }
        return await regions.origin()
    }

    func post<B: Encodable, R: Decodable>(
        path: String,
        body: B,
        responseType: R.Type,
        origin: URL? = nil
    ) async throws -> R {
        var request = URLRequest(url: await url(for: path, origin: origin))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("k9o-gate-swift", forHTTPHeaderField: "User-Agent")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw K9OGateError.decoding(error)
        }
        return try await execute(request: request, responseType: responseType)
    }

    /// POST (or another `method`) to `<origin>/@<projectSlug>/gate/<path>` for the end-user flows: an optional JSON body
    /// and an optional `Authorization: Bearer` header. With no `bearerToken` the call carries no credential.
    func send<R: Decodable>(
        method: String = "POST",
        path: String,
        body: (any Encodable)? = nil,
        bearerToken: String? = nil,
        responseType: R.Type,
        origin: URL? = nil
    ) async throws -> R {
        var request = URLRequest(url: await url(for: path, origin: origin))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("k9o-gate-swift", forHTTPHeaderField: "User-Agent")
        if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
            } catch {
                throw K9OGateError.decoding(error)
            }
        }
        return try await execute(request: request, responseType: responseType)
    }

    /// POST with no body and an `Authorization: Bearer` header, to `<origin>/@<projectSlug>/auth/<path>`.
    func postAuthorized<R: Decodable>(
        path: String,
        bearerToken: String,
        responseType: R.Type,
        origin: URL? = nil
    ) async throws -> R {
        var request = URLRequest(url: await url(for: path, origin: origin, area: "auth"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("k9o-gate-swift", forHTTPHeaderField: "User-Agent")
        return try await execute(request: request, responseType: responseType)
    }

    func get<R: Decodable>(path: String, bearerToken: String, responseType: R.Type) async throws -> R {
        var request = URLRequest(url: await url(for: path))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("k9o-gate-swift", forHTTPHeaderField: "User-Agent")
        return try await execute(request: request, responseType: responseType)
    }

    private func execute<R: Decodable>(request: URLRequest, responseType: R.Type) async throws -> R {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw K9OGateError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw K9OGateError.unknown(statusCode: -1, body: nil, requestId: nil)
        }
        guard (200...299).contains(http.statusCode) else {
            throw K9OGateError.from(
                statusCode: http.statusCode,
                data: data,
                mode: errorMode,
                requestId: http.value(forHTTPHeaderField: "x-k9o-request-id")
            )
        }
        do {
            let envelope = try decoder.decode(K9OEnvelope<R>.self, from: data)
            return envelope.data
        } catch {
            throw K9OGateError.decoding(error)
        }
    }
}

// MARK: - Request body shapes (internal; match the gateway OpenAPI)

struct SignInBody: Encodable {
    let email: String
    let password: String
}

/// The refresh body is closed to `{ refreshToken }`; the gateway refuses any other field.
struct RefreshTokenBody: Encodable {
    let refreshToken: String
}

struct SignOutBody: Encodable {
    let refreshToken: String
}

/// Type-erases an `Encodable` so a body can be passed as `any Encodable`.
struct AnyEncodable: Encodable {
    let wrapped: any Encodable
    init(_ wrapped: any Encodable) { self.wrapped = wrapped }
    func encode(to encoder: Encoder) throws { try wrapped.encode(to: encoder) }
}
