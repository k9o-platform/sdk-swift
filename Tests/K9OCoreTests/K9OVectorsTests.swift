import XCTest
@testable import K9OCore

private func hit(_ id: String, _ score: Double, chunk: Int) -> [String: Any] {
    ["id": id, "score": score, "_source": ["handle": "probe", "chunkIndex": chunk], "contentHash": NSNull(),
     "text": NSNull(), "metadata": [String: Any](), "model": NSNull(), "chunk": chunk]
}

final class K9OVectorsTests: XCTestCase {
    private let searchPath = "/@tasks-app/vectors/_vec_example/search"
    private let upsertPath = "/@tasks-app/vectors/_vec_example/upsert"

    func testNearestPostsVectorInBodyAndDecodesResultsClosestFirst() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: envelope([
            "results": [hit("p1", 1, chunk: 0), hit("p2", 0.8, chunk: 1)], "collection": "_vec_example",
        ])))
        let r = try await c.vectors.nearest("_vec_example", queryVector: [1, 0, 0], topK: 2, minScore: 0.5,
                                            metric: .dot, filters: ["metadata.lang": "en"])
        XCTAssertEqual(rec.last.httpMethod, "POST")
        XCTAssertEqual(rec.path, searchPath)
        XCTAssertEqual(rec.last.value(forHTTPHeaderField: "Authorization"), "Bearer tok_abc")
        let b = rec.lastBody
        XCTAssertEqual(b["queryVector"] as? [Double], [1, 0, 0])
        XCTAssertEqual(b["topK"] as? Int, 2)
        XCTAssertEqual(b["minScore"] as? Double, 0.5)
        XCTAssertEqual(b["metric"] as? String, "dot")
        XCTAssertEqual((b["filters"] as? [String: Any])?["metadata.lang"] as? String, "en")
        XCTAssertEqual(b.count, 5)
        XCTAssertEqual(r.data.collection, "_vec_example")
        XCTAssertEqual(r.data.results.map(\.id), ["p1", "p2"])
        XCTAssertEqual(r.data.results[1].score, 0.8)
        XCTAssertNil(r.data.results[0].contentHash)
        XCTAssertNil(r.data.results[0].text)
        XCTAssertNil(r.data.results[0].model)
        XCTAssertEqual(r.data.results[0].chunk, 0)
        XCTAssertEqual(r.data.results[0].source, K9OVectorSource(handle: "probe", chunkIndex: 0))
    }

    func testNearestOmitsOptionalFields() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: envelope(["results": [Any](), "collection": "_vec_example"])))
        _ = try await c.vectors.nearest("_vec_example", queryVector: [1, 0, 0])
        XCTAssertEqual(Set(rec.lastBody.keys), ["queryVector"])
    }

    func testInvalidNearestInputIsRefusedBeforeAnyRequest() async {
        let rec = Recorder()
        let v = makeClient(okTransport(rec)).vectors
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.nearest("notes", queryVector: [1]) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.nearest("_x", queryVector: []) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.nearest("_x", queryVector: Array(repeating: 0, count: 16001)) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.nearest("_x", queryVector: [1, .nan]) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.nearest("_x", queryVector: [1, .infinity]) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.nearest("_x", queryVector: [1], topK: 0) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.nearest("_x", queryVector: [1], topK: 1001) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.nearest("_x", queryVector: [1], minScore: .nan) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.nearest("_x", queryVector: [1], filters: ["a": .null]) }
        XCTAssertEqual(rec.count, 0)
    }

    func testMissingSlugIsRefusedBeforeAnyRequest() async {
        let rec = Recorder()
        let c = makeClient(okTransport(rec), slug: nil)
        await expectError("K9O_MISSING_PROJECT_CONTEXT") { _ = try await c.vectors.nearest("_x", queryVector: [1]) }
        XCTAssertEqual(rec.count, 0)
    }

    func test404CollectionNotFoundDecodesIntoAnError() async {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, status: 404, json: [
            "code": "K9O_COLLECTION_NOT_FOUND",
            "message": "derived vector collection '_vec_example' does not exist", "context": [String: Any](),
        ]))
        do {
            _ = try await c.vectors.nearest("_vec_example", queryVector: [1, 0, 0])
            XCTFail("expected an error")
        } catch let e as K9OError {
            XCTAssertEqual(e.code, "K9O_COLLECTION_NOT_FOUND")
            XCTAssertEqual(e.status, 404)
        } catch { XCTFail("\(error)") }
    }

    func test400InvalidVectorDimensionDecodesWithContext() async {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, status: 400, json: [
            "code": "K9O_INVALID_VECTOR_DIMENSION",
            "message": "query vector dimension does not match collection '_vec_example'",
            "context": ["collection": "_vec_example", "queryDim": 2],
        ]))
        do {
            _ = try await c.vectors.nearest("_vec_example", queryVector: [1, 0])
            XCTFail("expected an error")
        } catch let e as K9OError {
            XCTAssertEqual(e.code, "K9O_INVALID_VECTOR_DIMENSION")
            XCTAssertEqual(e.status, 400)
            XCTAssertEqual(e.context, .object(["collection": .string("_vec_example"), "queryDim": .number(2)]))
        } catch { XCTFail("\(error)") }
    }

    func testUpsertPostsRowsAndReturnsCount() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: envelope(["upserted": 3, "collection": "_vec_example"])))
        let r = try await c.vectors.upsert("_vec_example", rows: [
            K9OVectorRow(vector: [1, 0, 0], source: K9OVectorSource(handle: "probe", chunkIndex: 0), id: "p1",
                         text: "x", metadata: ["lang": .string("en")], subjectIds: ["eu_YmGE3Z6nkv5i"]),
            K9OVectorRow(vector: [0, 1, 0], source: K9OVectorSource(handle: "probe", chunkIndex: 1), contentHash: "h"),
        ])
        XCTAssertEqual(rec.last.httpMethod, "POST")
        XCTAssertEqual(rec.path, upsertPath)
        let rows = rec.lastBody["rows"] as! [[String: Any]]
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["id"] as? String, "p1")
        XCTAssertEqual(rows[0]["vector"] as? [Double], [1, 0, 0])
        XCTAssertEqual((rows[0]["_source"] as? [String: Any])?["handle"] as? String, "probe")
        XCTAssertEqual((rows[0]["_source"] as? [String: Any])?["chunkIndex"] as? Int, 0)
        XCTAssertEqual(rows[0]["text"] as? String, "x")
        XCTAssertEqual((rows[0]["metadata"] as? [String: Any])?["lang"] as? String, "en")
        XCTAssertEqual(rows[0]["subjectIds"] as? [String], ["eu_YmGE3Z6nkv5i"])
        XCTAssertEqual(Set(rows[1].keys), ["vector", "_source", "contentHash"])
        XCTAssertEqual(r.data.upserted, 3)
        XCTAssertEqual(r.data.collection, "_vec_example")
    }

    func testInvalidUpsertInputIsRefusedBeforeAnyRequest() async {
        let rec = Recorder()
        let v = makeClient(okTransport(rec)).vectors
        let src = K9OVectorSource(handle: "h", chunkIndex: 0)
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.upsert("notes", rows: [K9OVectorRow(vector: [1], source: src)]) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.upsert("_x", rows: []) }
        await expectError("K9O_INVALID_FIELD_VALUE") {
            _ = try await v.upsert("_x", rows: Array(repeating: K9OVectorRow(vector: [1], source: src), count: 1001))
        }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.upsert("_x", rows: [K9OVectorRow(vector: [], source: src)]) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await v.upsert("_x", rows: [K9OVectorRow(vector: [.nan], source: src)]) }
        XCTAssertEqual(rec.count, 0)
    }

    func testUpsert400InvalidVectorDimensionDecodesIntoAnError() async {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, status: 400, json: [
            "code": "K9O_INVALID_VECTOR_DIMENSION", "message": "rows differ in length",
            "context": ["index": 1, "expected": 3, "got": 2],
        ]))
        await expectError("K9O_INVALID_VECTOR_DIMENSION") {
            _ = try await c.vectors.upsert("_x", rows: [K9OVectorRow(vector: [1, 2, 3], source: K9OVectorSource(handle: "h", chunkIndex: 0))])
        }
    }
}
