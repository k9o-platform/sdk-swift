import XCTest
@testable import K9OCore

private let p1: [String: Any] = [
    "surface": "collection:posts", "scope": "posts", "recordId": "p1",
    "metadata": ["title": "Quarterly report", "tags": ["pinned", "finance"], "priority": 3, "embedding": "[1,0,0]"] as [String: Any],
]
private let telemetryRow: [String: Any] = [
    "surface": "telemetry:collection.metadata_index_declared", "scope": "collection.metadata_index_declared",
    "eventId": "aud_1",
    "metadata": ["id": "aud_1", "type": "collection.metadata_index_declared", "actorId": "usr_1",
                 "occurredAt": "2026-10-26T20:00:00.000Z"] as [String: Any],
]

private func page(_ rows: [[String: Any]], next: Any = NSNull()) -> [String: Any] {
    ["data": rows, "meta": ["requestId": "r1", "cursor": ["next": next]] as [String: Any]]
}

private func wire(_ any: Any?) -> [[String: Any]] { (any as? [[String: Any]]) ?? [] }

final class K9OMetadataTests: XCTestCase {
    private let base = "/@tasks-app/metadata"

    // MARK: filter

    func testFilterPostsSurfacesPrefixesFieldsAndReturnsRowsWithCursor() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: page([p1], next: "cur_1")))
        let r = try await c.metadata.filter(
            surfaces: ["collection:posts"],
            where: [K9OMetadataWhere("priority", .gte, .number(2)), K9OMetadataWhere("metadata.title", .startsWith, .string("Q"))],
            limit: 1, cursor: "cur_0")
        XCTAssertEqual(rec.last.httpMethod, "POST")
        XCTAssertEqual(rec.path, "\(base)/query")
        XCTAssertEqual(rec.query, [:])
        XCTAssertEqual(rec.last.value(forHTTPHeaderField: "Authorization"), "Bearer tok_abc")
        let b = rec.lastBody
        XCTAssertEqual(Set(b.keys), ["surfaces", "where", "limit", "cursor"])
        XCTAssertEqual(b["surfaces"] as? [String], ["collection:posts"])
        XCTAssertEqual(b["limit"] as? Int, 1)
        XCTAssertEqual(b["cursor"] as? String, "cur_0")
        let w = wire(b["where"])
        XCTAssertEqual(w.map { $0["field"] as? String }, ["metadata.priority", "metadata.title"])
        XCTAssertEqual(w.map { $0["op"] as? String }, ["gte", "startsWith"])
        XCTAssertEqual(w[0]["value"] as? Int, 2)
        XCTAssertEqual(w[1]["value"] as? String, "Q")
        XCTAssertEqual(r.nextCursor, "cur_1")
        XCTAssertEqual(r.data[0].recordId, "p1")
        XCTAssertEqual(r.data[0].metadata["priority"], .number(3))
    }

    func testFilterSendsOnlySurfacesByDefaultAndReportsNilCursor() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: page([p1, telemetryRow])))
        let r = try await c.metadata.filter(surfaces: ["collection:posts", "telemetry:collection.metadata_index_declared"])
        XCTAssertEqual(Set(rec.lastBody.keys), ["surfaces"])
        XCTAssertNil(r.nextCursor)
        XCTAssertEqual(r.data[1].eventId, "aud_1")
        XCTAssertNil(r.data[1].recordId)
    }

    func testFilterLeavesCreatedAtAndActorIdBareOnTelemetrySurface() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: page([telemetryRow])))
        _ = try await c.metadata.filter(surfaces: ["telemetry:collection."], where: [
            K9OMetadataWhere("createdAt", .gt, .string("2026-10-26T00:00:00Z")),
            K9OMetadataWhere("actorId", .eq, .string("usr_1")),
        ])
        XCTAssertEqual(wire(rec.lastBody["where"]).map { $0["field"] as? String }, ["createdAt", "actorId"])
    }

    func testFilterLetsStorageSurfaceThroughAndDecodes501() async {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, status: 501, json: [
            "code": "K9O_NOT_IMPLEMENTED", "message": "storage metadata is not available",
            "context": ["surface": "storage:photos"],
        ]))
        do {
            _ = try await c.metadata.filter(surfaces: ["storage:photos"])
            XCTFail("expected an error")
        } catch let e as K9OError {
            XCTAssertEqual(e.code, "K9O_NOT_IMPLEMENTED")
            XCTAssertEqual(e.status, 501)
            XCTAssertEqual(e.context, .object(["surface": .string("storage:photos")]))
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(rec.lastBody["surfaces"] as? [String], ["storage:photos"])
    }

    func testFilterDecodes413And400AndExtensionDenial() async {
        let big = makeClient(okTransport(Recorder(), status: 413, json: [
            "code": "K9O_QUERY_RESULT_TOO_LARGE", "message": "too many rows",
            "context": ["cap": 10000, "surfaces": ["collection:posts"]], "recommendation": "Add where or lower limit.",
        ]))
        do { _ = try await big.metadata.filter(surfaces: ["collection:posts"]); XCTFail("expected an error") } catch let e as K9OError {
            XCTAssertEqual([e.code, "\(e.status ?? 0)", e.recommendation ?? ""],
                           ["K9O_QUERY_RESULT_TOO_LARGE", "413", "Add where or lower limit."])
            guard case .object(let ctx)? = e.context else { return XCTFail("context") }
            XCTAssertEqual(ctx["cap"], .number(10000))
        } catch { XCTFail("\(error)") }

        let nope = makeClient(okTransport(Recorder(), status: 400, json: [
            "code": "K9O_METADATA_FIELD_NOT_INDEXED", "message": "not declared",
            "context": ["surface": "collection:posts", "field": "metadata.secret"], "recommendation": ["action": "declare it"],
        ]))
        do {
            _ = try await nope.metadata.filter(surfaces: ["collection:posts"], where: [K9OMetadataWhere("secret", .eq, .number(1))])
            XCTFail("expected an error")
        } catch let e as K9OError {
            XCTAssertEqual([e.code, e.recommendation ?? ""], ["K9O_METADATA_FIELD_NOT_INDEXED", "declare it"])
            XCTAssertEqual(e.status, 400)
        } catch { XCTFail("\(error)") }

        let denied = makeClient(okTransport(Recorder(), status: 403, json: [
            "code": "K9O_EXTENSION_PERMISSION_DENIED", "message": "no grant", "context": [String: Any](),
        ]))
        await expectError("K9O_EXTENSION_PERMISSION_DENIED") { _ = try await denied.metadata.filter(surfaces: ["collection:posts"]) }
    }

    func testFilterRefusesBadInputBeforeAnyRequest() async {
        let rec = Recorder()
        let m = makeClient(okTransport(rec)).metadata
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await m.filter(surfaces: []) }
        await expectError("K9O_UNKNOWN_SURFACE") { _ = try await m.filter(surfaces: ["posts"]) }
        await expectError("K9O_UNKNOWN_SURFACE") { _ = try await m.filter(surfaces: ["table:posts"]) }
        await expectError("K9O_UNKNOWN_SURFACE") { _ = try await m.filter(surfaces: ["collection:"]) }
        await expectError("K9O_UNKNOWN_SURFACE") { _ = try await m.filter(surfaces: ["collection:1posts"]) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await m.filter(surfaces: ["collection:posts", "telemetry:x"], cursor: "c") }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await m.filter(surfaces: ["collection:posts"], limit: 0) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await m.filter(surfaces: ["collection:posts"], limit: 1001) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await m.filter(surfaces: ["collection:posts"], cursor: "") }
        await expectError("K9O_INVALID_FIELD_VALUE") {
            _ = try await m.filter(surfaces: ["collection:posts"], where: [K9OMetadataWhere("", .eq, .number(1))])
        }
        XCTAssertEqual(rec.count, 0)
    }

    func testMissingSlugIsRefusedBeforeAnyRequest() async {
        let rec = Recorder()
        let c = makeClient(okTransport(rec), slug: nil)
        await expectError("K9O_MISSING_PROJECT_CONTEXT") { _ = try await c.metadata.filter(surfaces: ["collection:posts"]) }
        await expectError("K9O_MISSING_PROJECT_CONTEXT") { _ = try await c.metadata.index.get("posts") }
        XCTAssertEqual(rec.count, 0)
    }

    // MARK: set

    func testSetPatchesBareColumnsAndReturnsWholeRow() async throws {
        let rec = Recorder()
        let row: [String: Any] = ["id": "p2", "title": "Team offsite 2027", "priority": 9, "secret": "s2"]
        let c = makeClient(okTransport(rec, json: ["data": row, "meta": ["requestId": "r2"]]))
        let r = try await c.metadata.set("posts", id: "p 2", ["title": .string("Team offsite 2027"), "metadata.priority": .number(9)])
        XCTAssertEqual(rec.last.httpMethod, "PATCH")
        XCTAssertEqual(rec.path, "\(base)/collection/posts/p%202")
        let inner = rec.lastBody["metadata"] as? [String: Any]
        XCTAssertEqual(Set(rec.lastBody.keys), ["metadata"])
        XCTAssertEqual(inner?["title"] as? String, "Team offsite 2027")
        XCTAssertEqual(inner?["priority"] as? Int, 9)
        XCTAssertEqual(inner?.count, 2)
        XCTAssertEqual(r.data["id"], .string("p2"))
        XCTAssertEqual(r.data["secret"], .string("s2"))
    }

    func testSetRefusesBadInputBeforeAnyRequest() async {
        let rec = Recorder()
        let m = makeClient(okTransport(rec)).metadata
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await m.set("bad-name", id: "p1", ["a": .number(1)]) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await m.set("posts", id: "", ["a": .number(1)]) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await m.set("posts", id: "p1", [:]) }
        XCTAssertEqual(rec.count, 0)
    }

    func testSetDecodesNotDeclared() async {
        let c = makeClient(okTransport(Recorder(), status: 400, json: [
            "code": "K9O_METADATA_FIELD_NOT_INDEXED", "message": "x", "context": ["field": "metadata.nope"],
        ]))
        await expectError("K9O_METADATA_FIELD_NOT_INDEXED") { _ = try await c.metadata.set("posts", id: "p1", ["nope": .number(1)]) }
    }

    // MARK: search

    func testSearchPostsSurfacePrefixedFieldQAndLimit() async throws {
        let rec = Recorder()
        let hit: [String: Any] = ["surface": "collection:posts", "scope": "posts", "recordId": "p3",
                                  "metadata": ["title": "Budget draft"]]
        let c = makeClient(okTransport(rec, json: page([hit])))
        let r = try await c.metadata.search(surface: "collection:posts", field: "body", q: "finance", limit: 5)
        XCTAssertEqual(rec.last.httpMethod, "POST")
        XCTAssertEqual(rec.path, "\(base)/search")
        let b = rec.lastBody
        XCTAssertEqual(Set(b.keys), ["surface", "field", "q", "limit"])
        XCTAssertEqual(b["field"] as? String, "metadata.body")
        XCTAssertEqual(b["q"] as? String, "finance")
        XCTAssertEqual(b["limit"] as? Int, 5)
        XCTAssertEqual(r.data.map(\.recordId), ["p3"])
        XCTAssertNil(r.nextCursor)
    }

    func testSearchKeepsExistingPrefixAndOmitsLimit() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: page([])))
        _ = try await c.metadata.search(surface: "collection:posts", field: "metadata.body", q: "x")
        XCTAssertEqual(Set(rec.lastBody.keys), ["surface", "field", "q"])
        XCTAssertEqual(rec.lastBody["field"] as? String, "metadata.body")
    }

    func testSearchRefusesBadInputBeforeAnyRequestAndDecodesEncrypted() async {
        let rec = Recorder()
        let m = makeClient(okTransport(rec)).metadata
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await m.search(surface: "telemetry:x", field: "body", q: "a") }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await m.search(surface: "storage:b", field: "body", q: "a") }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await m.search(surface: "collection:posts", field: "", q: "a") }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await m.search(surface: "collection:posts", field: "body", q: "") }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await m.search(surface: "collection:posts", field: "body", q: "a", limit: 2000) }
        XCTAssertEqual(rec.count, 0)

        let enc = makeClient(okTransport(Recorder(), status: 400, json: [
            "code": "K9O_ENCRYPTED_COLUMN_OPERATION_UNSUPPORTED", "message": "x", "context": ["column": "body", "op": "textSearch"],
        ]))
        await expectError("K9O_ENCRYPTED_COLUMN_OPERATION_UNSUPPORTED") {
            _ = try await enc.metadata.search(surface: "collection:posts", field: "body", q: "a")
        }
    }

    // MARK: vectors.nearest

    func testNearestPostsPrefixedColumnEmbeddingAndOptions() async throws {
        let rec = Recorder()
        let hit: [String: Any] = ["surface": "collection:posts", "scope": "posts", "recordId": "p1",
                                  "metadata": ["title": "Quarterly report", "embedding": "[1,0,0]"]]
        let c = makeClient(okTransport(rec, json: page([hit])))
        let r = try await c.metadata.vectors.nearest(
            surface: "collection:posts", column: "embedding", embedding: [1, 0, 0], k: 3, metric: .dot,
            where: [K9OMetadataWhere("priority", .gt, .number(1))])
        XCTAssertEqual(rec.last.httpMethod, "POST")
        XCTAssertEqual(rec.path, "\(base)/vectors/nearest")
        let b = rec.lastBody
        XCTAssertEqual(Set(b.keys), ["surface", "column", "embedding", "k", "metric", "where"])
        XCTAssertEqual(b["column"] as? String, "metadata.embedding")
        XCTAssertEqual(b["embedding"] as? [Double], [1, 0, 0])
        XCTAssertEqual(b["k"] as? Int, 3)
        XCTAssertEqual(b["metric"] as? String, "dot")
        XCTAssertEqual(wire(b["where"]).first?["field"] as? String, "metadata.priority")
        XCTAssertEqual(r.data.first?.recordId, "p1")
    }

    func testNearestSendsOnlyRequiredFieldsByDefault() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: page([])))
        _ = try await c.metadata.vectors.nearest(surface: "collection:posts", column: "metadata.embedding", embedding: [0.5])
        XCTAssertEqual(Set(rec.lastBody.keys), ["surface", "column", "embedding"])
        XCTAssertEqual(rec.lastBody["column"] as? String, "metadata.embedding")
    }

    func testNearestRefusesBadInputBeforeAnyRequest() async {
        let rec = Recorder()
        let v = makeClient(okTransport(rec)).metadata.vectors
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.nearest(surface: "collection:posts", column: "e", embedding: []) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.nearest(surface: "collection:posts", column: "e", embedding: [1, .nan]) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.nearest(surface: "collection:posts", column: "e", embedding: [.infinity]) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.nearest(surface: "collection:posts", column: "e", embedding: [1], k: 0) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.nearest(surface: "collection:posts", column: "e", embedding: [1], k: 1001) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.nearest(surface: "telemetry:x", column: "e", embedding: [1]) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.nearest(surface: "collection:posts", column: "", embedding: [1]) }
        XCTAssertEqual(rec.count, 0)
    }

    // MARK: index

    private let indexJSON: [String: Any] = ["data": ["collection": "posts", "columns": [
        ["column": "body", "indexed": false], ["column": "tags", "indexed": true],
    ]], "meta": [String: Any]()]

    func testIndexGetReadsDeclaration() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: indexJSON))
        let r = try await c.metadata.index.get("posts")
        XCTAssertEqual(rec.last.httpMethod, "GET")
        XCTAssertEqual(rec.path, "\(base)/index/posts")
        XCTAssertNil(rec.last.httpBody)
        XCTAssertEqual(r.data.collection, "posts")
        XCTAssertEqual(r.data.columns[1], K9OMetadataIndex.Column(column: "tags", indexed: true))
    }

    func testIndexDeclareSendsPutAndAcceptsEmptyAnd64() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: indexJSON))
        _ = try await c.metadata.index.declare("posts", columns: [K9OMetadataColumn("body"), K9OMetadataColumn("tags", indexed: true)])
        XCTAssertEqual(rec.last.httpMethod, "PUT")
        XCTAssertEqual(rec.path, "\(base)/index/posts")
        let cols = wire(rec.lastBody["columns"])
        XCTAssertEqual(cols.map { $0["column"] as? String }, ["body", "tags"])
        XCTAssertNil(cols[0]["indexed"])
        XCTAssertEqual(cols[1]["indexed"] as? Bool, true)

        _ = try await c.metadata.index.declare("posts", columns: [])
        XCTAssertEqual(wire(rec.lastBody["columns"]).count, 0)
        _ = try await c.metadata.index.declare("posts", columns: (0..<64).map { K9OMetadataColumn("c\($0)") })
        XCTAssertEqual(wire(rec.lastBody["columns"]).count, 64)
        XCTAssertEqual(rec.count, 3)
    }

    func testIndexRefusesBadInputBeforeAnyRequest() async {
        let rec = Recorder()
        let i = makeClient(okTransport(rec)).metadata.index
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await i.declare("posts", columns: (0..<65).map { K9OMetadataColumn("c\($0)") }) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await i.declare("posts", columns: [K9OMetadataColumn("id")]) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await i.declare("posts", columns: [K9OMetadataColumn("a"), K9OMetadataColumn("a")]) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await i.declare("posts", columns: [K9OMetadataColumn("a b")]) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await i.declare("bad-name", columns: []) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await i.get("bad-name") }
        XCTAssertEqual(rec.count, 0)
    }

    func testIndexDecodesMissingCollectionAndDeniedRole() async {
        let missing = makeClient(okTransport(Recorder(), status: 404, json: ["code": "K9O_COLLECTION_NOT_FOUND", "message": "x"]))
        await expectError("K9O_COLLECTION_NOT_FOUND") { _ = try await missing.metadata.index.declare("ghost", columns: []) }
        let denied = makeClient(okTransport(Recorder(), status: 403, json: ["code": "K9O_IAM_POLICY_DENIED", "message": "x"]))
        await expectError("K9O_IAM_POLICY_DENIED") { _ = try await denied.metadata.index.declare("posts", columns: []) }
    }
}
