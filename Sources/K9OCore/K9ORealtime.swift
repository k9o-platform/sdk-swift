import Foundation

/// One event of a realtime topic, as the gateway frames it.
public struct K9ORealtimeEvent: Decodable, Sendable, Equatable {
    public let topic: String
    /// The event type within the topic family (for example `row_inserted`).
    public let eventType: String
    public let payload: K9OJSON
    public let occurredAt: String
    /// The event's id, the same on every gateway replica (`evt_...`).
    public let eventId: String

    public init(topic: String, eventType: String, payload: K9OJSON, occurredAt: String, eventId: String) {
        self.topic = topic
        self.eventType = eventType
        self.payload = payload
        self.occurredAt = occurredAt
        self.eventId = eventId
    }

    /// Decodes `payload` into your own type.
    public func decodePayload<T: Decodable>(as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(payload))
    }
}

/// Why the gateway could not resume a feed, from its `event: resync` frame.
public struct K9ORealtimeResync: Sendable, Equatable {
    public let reason: String
    public let action: String

    public init(reason: String, action: String) {
        self.reason = reason
        self.action = action
    }
}

/// An event from `realtime.replay`: the realtime event shape, with the ledger's `sequence`. A ledger event carries no stream `eventId`.
public struct K9ORealtimeReplayEvent: Decodable, Sendable, Equatable {
    public let topic: String
    public let eventType: String
    public let payload: K9OJSON
    public let occurredAt: String
    public let eventId: String?
    /// The event's position in the ledger (a string, as the gateway sends it).
    public let sequence: String?

    public init(topic: String, eventType: String, payload: K9OJSON, occurredAt: String, eventId: String? = nil,
                sequence: String? = nil) {
        self.topic = topic
        self.eventType = eventType
        self.payload = payload
        self.occurredAt = occurredAt
        self.eventId = eventId
        self.sequence = sequence
    }

    private enum CodingKeys: String, CodingKey { case topic, eventType, payload, occurredAt, eventId, sequence }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topic = (try? c.decode(String.self, forKey: .topic)) ?? ""
        eventType = try c.decode(String.self, forKey: .eventType)
        payload = (try? c.decode(K9OJSON.self, forKey: .payload)) ?? .null
        occurredAt = (try? c.decode(String.self, forKey: .occurredAt)) ?? ""
        if let id = try? c.decode(String.self, forKey: .eventId), !id.isEmpty { eventId = id } else { eventId = nil }
        if let s = try? c.decode(String.self, forKey: .sequence) { sequence = s }
        else if let n = try? c.decode(Int.self, forKey: .sequence) { sequence = String(n) }
        else { sequence = nil }
    }

    /// Decodes `payload` into your own type.
    public func decodePayload<T: Decodable>(as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(payload))
    }
}

/// One answer of `realtime.replay`.
public struct K9ORealtimeReplayPage: Decodable, Sendable, Equatable {
    public let topic: String
    public let events: [K9ORealtimeReplayEvent]
    /// Where the next call starts (the last event's `sequence`), or nil when there is none.
    public let nextCursor: String?
    /// True when more events follow this page.
    public let hasMore: Bool
    /// `reread-source` when the topic keeps no ledger: read current state from the data plane instead.
    public let resync: String?

    public init(topic: String, events: [K9ORealtimeReplayEvent], nextCursor: String?, hasMore: Bool, resync: String? = nil) {
        self.topic = topic
        self.events = events
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.resync = resync
    }

    private enum CodingKeys: String, CodingKey { case topic, events, nextCursor, hasMore, resync }

    /// Items without an `eventType` are skipped.
    private struct Lossy: Decodable {
        let value: K9ORealtimeReplayEvent?
        init(from decoder: Decoder) throws { value = try? K9ORealtimeReplayEvent(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topic = (try? c.decode(String.self, forKey: .topic)) ?? ""
        events = ((try? c.decode([Lossy].self, forKey: .events)) ?? []).compactMap(\.value)
        if let s = try? c.decode(String.self, forKey: .nextCursor) { nextCursor = s }
        else if let n = try? c.decode(Int.self, forKey: .nextCursor) { nextCursor = String(n) }
        else { nextCursor = nil }
        hasMore = (try? c.decode(Bool.self, forKey: .hasMore)) ?? false
        if let r = try? c.decode(String.self, forKey: .resync) { resync = r } else { resync = nil }
    }
}

private struct RealtimeReplayBody: Encodable {
    let topic: String
    let fromSequence: String?
    let untilSequence: String?
    let limit: Int?
    let afterAuditEventId: String?
    private enum K: String, CodingKey { case topic, fromSequence, untilSequence, limit, afterAuditEventId }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(topic, forKey: .topic)
        try c.encodeIfPresent(fromSequence, forKey: .fromSequence)
        try c.encodeIfPresent(untilSequence, forKey: .untilSequence)
        try c.encodeIfPresent(limit, forKey: .limit)
        try c.encodeIfPresent(afterAuditEventId, forKey: .afterAuditEventId)
    }
}

/// The ids of recently yielded events, bounded by count and by age, so the events a resume re-sends are dropped.
struct K9ORealtimeSeen {
    private var seen: [String: Date] = [:]
    private var order: [String] = []
    private let max: Int
    private let ttl: TimeInterval

    init(max: Int = 1000, ttl: TimeInterval = 60) {
        self.max = max
        self.ttl = ttl
    }

    /// True the first time an id is offered (and remembers it); false for a duplicate still remembered.
    mutating func firstTime(_ id: String, now: Date = Date()) -> Bool {
        while let oldest = order.first, let at = seen[oldest], now.timeIntervalSince(at) > ttl || order.count > max {
            order.removeFirst()
            seen[oldest] = nil
        }
        if seen[id] != nil { return false }
        seen[id] = now
        order.append(id)
        if order.count > max, let oldest = order.first {
            order.removeFirst()
            seen[oldest] = nil
        }
        return true
    }
}

/// Realtime change feeds (`/@<projectSlug>/realtime`). `subscribe` tails a topic over Server-Sent Events;
/// `replay` reads a topic's ledger. Gateway codes such as `K9O_INVALID_FILTER`, `K9O_SUBSCRIPTION_LIMIT_EXCEEDED` and
/// `K9O_TIER_FEATURE_GATED` arrive as `K9OError`. A filter narrows the events and the project's row-level access
/// still gates them.
public struct K9ORealtime: Sendable {
    let client: K9OCoreClient

    static let replayMax = 10_000
    static let maxReconnectMs = 30_000

    /// `GET /@<projectSlug>/realtime/subscribe?topic=&filter=` (Server-Sent Events): tail a topic live.
    ///
    /// Returns an async sequence of events. The gateway closes each connection after a while; the subscription
    /// reopens it by itself with `Last-Event-ID` set to the last event received and yields each event once (a resume
    /// can re-send a few events, which are dropped by `eventId`). The sequence ends when you stop iterating or cancel
    /// the task. A 4xx answer ends it by throwing; a 5xx answer or a broken connection is retried after a delay
    /// (`retryDelayMs`, else the server's hint, else 1000 ms, backing off to 30000 ms on repeated failures).
    /// When the gateway cannot resume (`event: resync`), events may have been missed: `onResync` is called and the
    /// subscription carries on live from a fresh connection; without `onResync` the sequence ends there.
    /// `filter` is a per-topic predicate sent as JSON. Throws `K9O_MISSING_PROJECT_CONTEXT` when the client has no
    /// `projectSlug`.
    public func subscribe(_ topic: String, filter: [String: K9OJSON]? = nil, retryDelayMs: Int? = nil,
                          dedupeMax: Int = 1000, dedupeTtlSeconds: Double = 60,
                          onResync: (@Sendable (K9ORealtimeResync) async -> Void)? = nil)
        throws -> AsyncThrowingStream<K9ORealtimeEvent, Error> {
        let slug = try client.requireProject("realtime operations")
        let target = "/@\(slug)/realtime/subscribe"
        var query: [(String, String)] = [("topic", topic)]
        if let filter {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            query.append(("filter", String(decoding: try enc.encode(K9OJSON.object(filter)), as: UTF8.self)))
        }
        let client = self.client
        let baseQuery = query
        return AsyncThrowingStream { continuation in
            let task = Task {
                var lastEventId: String?
                var seen = K9ORealtimeSeen(max: dedupeMax, ttl: dedupeTtlSeconds)
                var serverRetryMs = 1000
                var failures = 0
                do {
                    while !Task.isCancelled {
                        var gotFrame = false
                        var resynced = false
                        var sawData = false
                        var ended = false
                        let request = try await client.makeRequest(
                            method: "GET", path: target, query: baseQuery, accept: "text/event-stream", body: nil,
                            headers: lastEventId.map { [("Last-Event-ID", $0)] } ?? [])
                        var opened: (AsyncThrowingStream<Data, Error>, URLResponse)?
                        do {
                            opened = try await client.streamTransport(request)
                        } catch {
                            if Task.isCancelled { break }
                            opened = nil  // a network failure is retried
                        }
                        if let (chunks, response) = opened {
                            guard let http = response as? HTTPURLResponse else {
                                throw K9OError(code: K9OError.upstreamUnavailable, message: "No HTTP response")
                            }
                            if (200...299).contains(http.statusCode) {
                                var parser = K9OSSEParser()
                                // 0 = keep reading, 1 = reconnect, 2 = end the subscription.
                                func process(_ f: K9OSSEFrame) async -> Int {
                                    if let r = f.retry { serverRetryMs = min(r, K9ORealtime.maxReconnectMs) }
                                    if f.event == "resync" {
                                        // A resync that opens a connection made without Last-Event-ID, before any data
                                        // frame, only reports the head of the stream: keep reading.
                                        if lastEventId == nil && !sawData {
                                            gotFrame = true
                                            failures = 0
                                            return 0
                                        }
                                        gotFrame = true
                                        failures = 0
                                        resynced = true
                                        lastEventId = nil
                                        seen = K9ORealtimeSeen(max: dedupeMax, ttl: dedupeTtlSeconds)
                                        guard let onResync else { return 2 }
                                        await onResync(K9ORealtime.resyncInfo(f))
                                        return 1
                                    }
                                    guard let text = f.data else { return 0 }
                                    sawData = true
                                    guard let decoded = K9ORealtime.decodeFrame(f, text) else { return 0 }
                                    gotFrame = true
                                    failures = 0
                                    // Resume from the SSE `id:` (the cursor the gateway issues); the event's own id is for dedupe only.
                                    let cursor = (f.id ?? "").isEmpty ? decoded.eventId : f.id!
                                    if !cursor.isEmpty { lastEventId = cursor }
                                    if !decoded.eventId.isEmpty && !seen.firstTime(decoded.eventId) { return 0 }
                                    if case .terminated = continuation.yield(decoded) { return 2 }
                                    return 0
                                }
                                var step = 0
                                do {
                                    read: for try await chunk in chunks {
                                        if Task.isCancelled { break }
                                        for f in parser.feed(chunk) {
                                            step = await process(f)
                                            if step != 0 { break read }
                                        }
                                    }
                                    if step == 0 {
                                        for f in parser.finish() {
                                            step = await process(f)
                                            if step != 0 { break }
                                        }
                                    }
                                } catch {
                                    // A break in the connection is treated like the server closing it.
                                    if Task.isCancelled { break }
                                }
                                if step == 2 { ended = true }
                            } else {
                                var body = Data()
                                for try await c in chunks { body.append(c) }
                                // A client error will not get better by asking again.
                                if (400..<500).contains(http.statusCode) {
                                    throw K9OError.fromResponse(status: http.statusCode, data: body, response: http)
                                }
                            }
                        }
                        if ended || Task.isCancelled { break }
                        if !gotFrame { failures += 1 }
                        let base = retryDelayMs ?? serverRetryMs
                        let waitMs = (resynced || failures == 0)
                            ? base : min(base << min(failures - 1, 16), K9ORealtime.maxReconnectMs)
                        try? await Task.sleep(nanoseconds: UInt64(max(waitMs, 0)) * 1_000_000)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `POST /@<projectSlug>/realtime/replay`: one call of the topic's ledger catch-up. The answer is
    /// `{topic, events, nextCursor, hasMore, resync}`; events have the realtime shape plus the ledger's `sequence`.
    /// Page on with `fromSequence` (set it to `nextCursor`) while `hasMore` is true. Only `audit.project.*` topics keep
    /// a ledger (they need the audit log's access: 403 `K9O_RBAC_DENY` otherwise; an unknown `afterAuditEventId`
    /// answers 400 `K9O_INVALID_CURSOR`). For any other topic the answer has no events and `resync` is
    /// `reread-source`: read current state, then `subscribe`.
    ///
    /// `topic` is 1 to 200 characters. `fromSequence` and `untilSequence` are non-negative whole numbers sent as
    /// strings. `limit` is 1 to 10000. `afterAuditEventId` looks like `evt_` followed by 1 to 40 letters and digits.
    /// Invalid input throws `K9O_INVALID_FIELD_VALUE` before any request.
    public func replay(_ topic: String, fromSequence: String? = nil, untilSequence: String? = nil, limit: Int? = nil,
                       afterAuditEventId: String? = nil) async throws -> K9OEnvelope<K9ORealtimeReplayPage> {
        let slug = try client.requireProject("realtime operations")
        if topic.isEmpty || topic.count > 200 {
            throw K9OError.invalidField("realtime.replay: topic must be a non-empty string of at most 200 characters",
                                        context: .object(["field": .string("topic")]))
        }
        try Self.checkSequence("fromSequence", fromSequence)
        try Self.checkSequence("untilSequence", untilSequence)
        if let afterAuditEventId, !Self.isAuditEventId(afterAuditEventId) {
            throw K9OError.invalidField("realtime.replay: afterAuditEventId must look like evt_ followed by letters and digits",
                                        context: .object(["field": .string("afterAuditEventId")]))
        }
        if let limit, limit < 1 || limit > Self.replayMax {
            throw K9OError.invalidField("realtime.replay: limit must be an integer from 1 to 10000",
                                        context: .object(["field": .string("limit")]),
                                        recommendation: "Pass a limit from 1 to 10000, or leave it out.")
        }
        return try await client.post(
            path: "/@\(slug)/realtime/replay",
            body: RealtimeReplayBody(topic: topic, fromSequence: fromSequence, untilSequence: untilSequence, limit: limit,
                                     afterAuditEventId: afterAuditEventId),
            as: K9ORealtimeReplayPage.self)
    }

    static func checkSequence(_ name: String, _ v: String?) throws {
        guard let v else { return }
        if v.isEmpty || !v.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
            throw K9OError.invalidField("realtime.replay: \(name) must be a non-negative integer",
                                        context: .object(["field": .string(name)]),
                                        recommendation: "Pass \(name) as a string of digits.")
        }
    }

    static func isAuditEventId(_ s: String) -> Bool {
        guard s.hasPrefix("evt_") else { return false }
        let rest = s.utf8.dropFirst(4)
        return (1...40).contains(rest.count) && rest.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
        }
    }

    private struct Wire: Decodable {
        let topic: String?
        let eventType: String?
        let payload: K9OJSON?
        let occurredAt: String?
        let eventId: String?
    }

    static func decodeFrame(_ f: K9OSSEFrame, _ text: String) -> K9ORealtimeEvent? {
        guard let w = try? JSONDecoder().decode(Wire.self, from: Data(text.utf8)), let type = w.eventType else { return nil }
        return K9ORealtimeEvent(topic: w.topic ?? "", eventType: type, payload: w.payload ?? .null,
                                occurredAt: w.occurredAt ?? "", eventId: w.eventId ?? f.id ?? "")
    }

    static func resyncInfo(_ f: K9OSSEFrame) -> K9ORealtimeResync {
        var reason = "cursor-unknown"
        var action = "reread-source"
        if let text = f.data, case .object(let o)? = try? JSONDecoder().decode(K9OJSON.self, from: Data(text.utf8)) {
            if case .string(let r)? = o["reason"] { reason = r }
            if case .string(let a)? = o["action"] { action = a }
        }
        return K9ORealtimeResync(reason: reason, action: action)
    }
}
