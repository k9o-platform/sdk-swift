import XCTest
@testable import K9OCore

final class K9ORealtimeTests: XCTestCase {
    private func ev(_ id: String, _ n: Int, type: String = "row_inserted") -> String {
        "{\"topic\":\"collections.posts.*\",\"eventType\":\"\(type)\",\"payload\":{\"n\":\(n)},\"occurredAt\":\"2026-11-13T10:00:00Z\",\"eventId\":\"\(id)\"}"
    }

    private func frames(_ items: [(id: String?, event: String?, data: String)], retry: Int? = nil) -> Data {
        var s = retry.map { "retry: \($0)\n\n" } ?? ""
        for i in items {
            if let id = i.id { s += "id: \(id)\n" }
            if let e = i.event { s += "event: \(e)\n" }
            s += "data: \(i.data)\n\n"
        }
        return Data(s.utf8)
    }

    private func streamTransport(_ rec: Recorder, status: Int = 200,
                                 _ bodies: @escaping @Sendable (Int) -> (Data, Bool)) -> K9OStreamTransport {
        let calls = Counter()
        return { req in
            rec.requests.append(req)
            let n = calls.next()
            let (data, closes) = bodies(n)
            let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
            return (AsyncThrowingStream { c in
                c.yield(data)
                if closes { c.finish() }
            }, resp)
        }
    }

    // MARK: subscribe

    func testSubscribeSendsTopicAndFilterAndYieldsEvents() async throws {
        let rec = Recorder()
        let t = streamTransport(rec) { _ in
            (self.frames([(id: "c1", event: nil, data: self.ev("evt_a", 1))]), false)
        }
        let client = makeClient(okTransport(rec), stream: t)
        var got: [K9ORealtimeEvent] = []
        for try await e in try client.realtime.subscribe("collections.posts.*", filter: ["status": .string("open")]) {
            got.append(e)
            break
        }
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].eventType, "row_inserted")
        XCTAssertEqual(got[0].eventId, "evt_a")
        XCTAssertEqual(got[0].topic, "collections.posts.*")
        XCTAssertEqual(got[0].payload, .object(["n": .number(1)]))
        XCTAssertEqual(rec.path, "/@tasks-app/realtime/subscribe")
        XCTAssertEqual(rec.query["topic"], "collections.posts.*")
        XCTAssertEqual(rec.query["filter"], "{\"status\":\"open\"}")
        XCTAssertEqual(rec.last.httpMethod, "GET")
        XCTAssertEqual(rec.last.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(rec.last.value(forHTTPHeaderField: "Authorization"), "Bearer tok_abc")
        XCTAssertNil(rec.last.value(forHTTPHeaderField: "Last-Event-ID"))
    }

    func testSubscribeOmitsFilterWhenNone() async throws {
        let rec = Recorder()
        let t = streamTransport(rec) { _ in (self.frames([(id: "c1", event: nil, data: self.ev("evt_a", 1))]), false) }
        for try await _ in try makeClient(okTransport(rec), stream: t).realtime.subscribe("collections.posts.*") { break }
        XCTAssertNil(rec.query["filter"])
    }

    func testSubscribeReconnectsWithLastEventIdAndDropsResentEvents() async throws {
        let rec = Recorder()
        let first = frames([(id: "c1", event: nil, data: ev("evt_a", 1)), (id: "c2", event: nil, data: ev("evt_b", 2))], retry: 1)
        let second = frames([(id: "c2", event: nil, data: ev("evt_b", 2)), (id: "c3", event: nil, data: ev("evt_c", 3))])
        let t = streamTransport(rec) { n in n == 0 ? (first, true) : (second, false) }
        var got: [String] = []
        for try await e in try makeClient(okTransport(rec), stream: t).realtime.subscribe("collections.posts.*") {
            got.append(e.eventId)
            if got.count == 3 { break }
        }
        XCTAssertEqual(got, ["evt_a", "evt_b", "evt_c"])
        XCTAssertEqual(rec.requests.count, 2)
        XCTAssertNil(rec.requests[0].value(forHTTPHeaderField: "Last-Event-ID"))
        XCTAssertEqual(rec.requests[1].value(forHTTPHeaderField: "Last-Event-ID"), "c2")
    }

    func testSubscribeUsesFrameIdWhenDataHasNoEventId() async throws {
        let rec = Recorder()
        let bare = "{\"eventType\":\"x\",\"payload\":null,\"occurredAt\":\"t\"}"
        let t = streamTransport(rec) { _ in (self.frames([(id: "evt_z", event: nil, data: bare)]), false) }
        for try await e in try makeClient(okTransport(rec), stream: t).realtime.subscribe("t") {
            XCTAssertEqual(e.eventId, "evt_z")
            XCTAssertEqual(e.payload, .null)
            break
        }
    }

    func testSubscribeSkipsFramesWithoutEventType() async throws {
        let rec = Recorder()
        let payload = Data(("data: not json\n\ndata: {\"x\":1}\n\n: hb\n\n" + "id: c9\ndata: \(ev("evt_9", 9))\n\n").utf8)
        let t = streamTransport(rec) { _ in (payload, false) }
        for try await e in try makeClient(okTransport(rec), stream: t).realtime.subscribe("t") {
            XCTAssertEqual(e.eventId, "evt_9")
            break
        }
    }

    func testSubscribeResyncCallsHandlerThenReconnectsLiveWithoutLastEventId() async throws {
        let rec = Recorder()
        let resyncs = ResyncBox()
        let first = frames([(id: "c1", event: nil, data: ev("evt_a", 1)),
                            (id: nil, event: "resync", data: "{\"reason\":\"cursor-expired\",\"action\":\"reread-source\"}")], retry: 1)
        let second = frames([(id: "c5", event: nil, data: ev("evt_e", 5))])
        let t = streamTransport(rec) { n in n == 0 ? (first, false) : (second, false) }
        var got: [String] = []
        let sub = try makeClient(okTransport(rec), stream: t).realtime.subscribe("t", retryDelayMs: 1) { r in
            resyncs.add(r)
        }
        for try await e in sub {
            got.append(e.eventId)
            if got.count == 2 { break }
        }
        XCTAssertEqual(got, ["evt_a", "evt_e"])
        XCTAssertEqual(resyncs.items, [K9ORealtimeResync(reason: "cursor-expired", action: "reread-source")])
        XCTAssertEqual(rec.requests.count, 2)
        XCTAssertNil(rec.requests[1].value(forHTTPHeaderField: "Last-Event-ID"))
    }

    func testSubscribeResyncWithoutHandlerEndsTheSequence() async throws {
        let rec = Recorder()
        let body = frames([(id: "c1", event: nil, data: ev("evt_a", 1)),
                           (id: nil, event: "resync", data: "{\"reason\":\"cursor-unknown\"}")])
        let t = streamTransport(rec) { _ in (body, false) }
        var got: [String] = []
        for try await e in try makeClient(okTransport(rec), stream: t).realtime.subscribe("t") { got.append(e.eventId) }
        XCTAssertEqual(got, ["evt_a"])
        XCTAssertEqual(rec.requests.count, 1)
    }

    func testSubscribeLeadingResyncOnFreshConnectionIsSkipped() async throws {
        let rec = Recorder()
        let resyncs = ResyncBox()
        let body = frames([(id: nil, event: "resync", data: "{\"reason\":\"head\"}"),
                           (id: "c1", event: nil, data: ev("evt_a", 1))])
        let t = streamTransport(rec) { _ in (body, false) }
        let sub = try makeClient(okTransport(rec), stream: t).realtime.subscribe("t") { resyncs.add($0) }
        for try await e in sub {
            XCTAssertEqual(e.eventId, "evt_a")
            break
        }
        XCTAssertEqual(resyncs.items.count, 0)
        XCTAssertEqual(rec.requests.count, 1)
    }

    func testSubscribe4xxThrowsGatewayCodeWithoutRetry() async {
        let rec = Recorder()
        let t = streamTransport(rec, status: 400) { _ in
            (Data("{\"code\":\"K9O_INVALID_FILTER\",\"message\":\"bad filter\"}".utf8), true)
        }
        await expectError("K9O_INVALID_FILTER") {
            for try await _ in try makeClient(okTransport(rec), stream: t).realtime.subscribe("t") {}
        }
        XCTAssertEqual(rec.requests.count, 1)
    }

    func testSubscribe5xxIsRetried() async throws {
        let rec = Recorder()
        let calls = Counter()
        let t: K9OStreamTransport = { req in
            rec.requests.append(req)
            let n = calls.next()
            let resp = HTTPURLResponse(url: req.url!, statusCode: n == 0 ? 503 : 200, httpVersion: nil, headerFields: nil)!
            return (AsyncThrowingStream { c in
                c.yield(n == 0 ? Data("{\"code\":\"K9O_UPSTREAM_UNAVAILABLE\"}".utf8)
                               : self.frames([(id: "c1", event: nil, data: self.ev("evt_a", 1))]))
                if n == 0 { c.finish() }
            }, resp)
        }
        for try await e in try makeClient(okTransport(rec), stream: t).realtime.subscribe("t", retryDelayMs: 1) {
            XCTAssertEqual(e.eventId, "evt_a")
            break
        }
        XCTAssertEqual(rec.requests.count, 2)
    }

    func testSubscribeNeedsProjectSlug() {
        let rec = Recorder()
        XCTAssertThrowsError(try makeClient(okTransport(rec), slug: nil).realtime.subscribe("t")) {
            XCTAssertEqual(($0 as? K9OError)?.code, "K9O_MISSING_PROJECT_CONTEXT")
        }
    }

    func testSeenDropsDuplicatesWithinCountAndTtl() {
        var s = K9ORealtimeSeen(max: 2, ttl: 10)
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(s.firstTime("a", now: t0))
        XCTAssertFalse(s.firstTime("a", now: t0))
        XCTAssertTrue(s.firstTime("b", now: t0))
        XCTAssertTrue(s.firstTime("c", now: t0))             // evicts "a" by count
        XCTAssertTrue(s.firstTime("a", now: t0))
        XCTAssertTrue(s.firstTime("b", now: t0.addingTimeInterval(11)))  // expired by age
    }

    // MARK: replay

    func testReplayPostsBodyAndDecodesPage() async throws {
        let rec = Recorder()
        let page: [String: Any] = [
            "topic": "audit.project.*",
            "events": [
                ["topic": "audit.project.members", "eventType": "member.added", "payload": ["id": 1],
                 "occurredAt": "2026-11-13T10:00:00Z", "sequence": 7, "eventId": "evt_q"],
                ["eventType": "member.removed", "payload": NSNull(), "occurredAt": "t", "sequence": "8"],
                ["noType": true],
            ],
            "nextCursor": 8, "hasMore": true,
        ]
        let c = makeClient(okTransport(rec, json: envelope(page)))
        let r = try await c.realtime.replay("audit.project.*", fromSequence: "6", untilSequence: "20", limit: 2,
                                            afterAuditEventId: "evt_abc123")
        XCTAssertEqual(rec.path, "/@tasks-app/realtime/replay")
        XCTAssertEqual(rec.last.httpMethod, "POST")
        XCTAssertEqual(rec.lastBody["topic"] as? String, "audit.project.*")
        XCTAssertEqual(rec.lastBody["fromSequence"] as? String, "6")
        XCTAssertEqual(rec.lastBody["untilSequence"] as? String, "20")
        XCTAssertEqual(rec.lastBody["limit"] as? Int, 2)
        XCTAssertEqual(rec.lastBody["afterAuditEventId"] as? String, "evt_abc123")
        XCTAssertEqual(r.data.topic, "audit.project.*")
        XCTAssertEqual(r.data.events.count, 2)
        XCTAssertEqual(r.data.events[0].sequence, "7")
        XCTAssertEqual(r.data.events[0].eventId, "evt_q")
        XCTAssertEqual(r.data.events[0].payload, .object(["id": .number(1)]))
        XCTAssertEqual(r.data.events[1].topic, "")
        XCTAssertNil(r.data.events[1].eventId)
        XCTAssertEqual(r.data.events[1].sequence, "8")
        XCTAssertEqual(r.data.nextCursor, "8")
        XCTAssertTrue(r.data.hasMore)
        XCTAssertNil(r.data.resync)
    }

    func testReplayOmitsOptionalFieldsAndReadsResync() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: envelope(
            ["topic": "collections.posts.*", "events": [], "nextCursor": NSNull(), "hasMore": false, "resync": "reread-source"])))
        let r = try await c.realtime.replay("collections.posts.*")
        XCTAssertEqual(Set(rec.lastBody.keys), ["topic"])
        XCTAssertEqual(r.data.resync, "reread-source")
        XCTAssertNil(r.data.nextCursor)
        XCTAssertFalse(r.data.hasMore)
        XCTAssertEqual(r.data.events, [])
    }

    func testReplayValidatesBeforeAnyRequest() async {
        let rec = Recorder()
        let c = makeClient(okTransport(rec))
        await expectError("K9O_INVALID_FIELD_VALUE", contains: "topic") { _ = try await c.realtime.replay("") }
        await expectError("K9O_INVALID_FIELD_VALUE", contains: "topic") {
            _ = try await c.realtime.replay(String(repeating: "a", count: 201))
        }
        await expectError("K9O_INVALID_FIELD_VALUE", contains: "fromSequence") {
            _ = try await c.realtime.replay("t", fromSequence: "-1")
        }
        await expectError("K9O_INVALID_FIELD_VALUE", contains: "fromSequence") {
            _ = try await c.realtime.replay("t", fromSequence: "1.5")
        }
        await expectError("K9O_INVALID_FIELD_VALUE", contains: "untilSequence") {
            _ = try await c.realtime.replay("t", untilSequence: "")
        }
        await expectError("K9O_INVALID_FIELD_VALUE", contains: "limit") { _ = try await c.realtime.replay("t", limit: 0) }
        await expectError("K9O_INVALID_FIELD_VALUE", contains: "limit") { _ = try await c.realtime.replay("t", limit: 10_001) }
        for bad in ["abc", "evt_", "evt_a-b", "evt_" + String(repeating: "a", count: 41)] {
            await expectError("K9O_INVALID_FIELD_VALUE", contains: "afterAuditEventId") {
                _ = try await c.realtime.replay("t", afterAuditEventId: bad)
            }
        }
        XCTAssertEqual(rec.count, 0)
    }

    func testReplayAcceptsBoundaryValues() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: envelope(["topic": "t", "events": [], "hasMore": false])))
        _ = try await c.realtime.replay(String(repeating: "a", count: 200), fromSequence: "0", limit: 1)
        _ = try await c.realtime.replay("t", limit: 10_000, afterAuditEventId: "evt_" + String(repeating: "Z9", count: 20))
        XCTAssertEqual(rec.count, 2)
    }

    func testReplayErrorSurfacesAndNeedsProject() async {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, status: 403, json: ["code": "K9O_RBAC_DENY", "message": "no"]))
        await expectError("K9O_RBAC_DENY") { _ = try await c.realtime.replay("audit.project.*") }
        await expectError("K9O_MISSING_PROJECT_CONTEXT") {
            _ = try await makeClient(okTransport(rec), slug: nil).realtime.replay("t")
        }
    }
}

final class ResyncBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [K9ORealtimeResync] = []
    func add(_ r: K9ORealtimeResync) { lock.lock(); list.append(r); lock.unlock() }
    var items: [K9ORealtimeResync] { lock.lock(); defer { lock.unlock() }; return list }
}
