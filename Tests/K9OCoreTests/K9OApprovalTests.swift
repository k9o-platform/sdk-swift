import XCTest
@testable import K9OCore

final class K9OApprovalTests: XCTestCase {
    private func queued(_ operation: String, target: Any, payload: [String: Any]) -> [String: Any] {
        [
            "data": [
                "id": "apr_5oLshD2MVT27", "status": "pending_approval", "collection": "conformance_kv",
                "operation": operation, "makerId": "usr_conformance0001", "proposedPayload": payload,
                "targetRecordId": target,
            ],
            "meta": [
                "cost": [String: Any](), "timing": [String: Any](),
                "context": ["requestId": "req_1", "traceId": "req_1", "projectId": "proj_1"],
                "approval": ["status": "pending_approval"],
            ] as [String: Any],
        ]
    }

    private func client(_ rec: Recorder, status: Int = 200, json: Any) -> K9OCoreClient {
        makeClient(okTransport(rec, status: status, json: json))
    }

    func testInsertSendsFlagAndDecodesQueuedChange() async throws {
        let rec = Recorder()
        let record = ["id": K9OJSON.string("contract2-probe-0001"), "val": K9OJSON.string("contract2-probe")]
        let c = client(rec, status: 202, json: queued("insert", target: NSNull(), payload: ["id": "contract2-probe-0001", "val": "contract2-probe"]))
        let r = try await c.from("conformance_kv").insertForApproval(record).execute()
        XCTAssertEqual(rec.last.httpMethod, "POST")
        XCTAssertEqual(rec.path, "/@tasks-app/data/conformance_kv")
        XCTAssertEqual(rec.last.url?.query, "requireApproval=true")
        XCTAssertEqual(rec.lastBody as? [String: String], ["id": "contract2-probe-0001", "val": "contract2-probe"])
        guard case .queued(let change, let meta) = r else { return XCTFail("expected a queued write") }
        XCTAssertEqual(change.id, "apr_5oLshD2MVT27")
        XCTAssertEqual(change.status, "pending_approval")
        XCTAssertEqual(change.operation, "insert")
        XCTAssertEqual(change.collection, "conformance_kv")
        XCTAssertEqual(change.makerId, "usr_conformance0001")
        XCTAssertEqual(change.proposedPayload["id"], .string("contract2-probe-0001"))
        XCTAssertNil(change.targetRecordId)
        XCTAssertEqual(meta["approval"], .object(["status": .string("pending_approval")]))
    }

    func testInsertDecodesAppliedRow() async throws {
        let rec = Recorder()
        let c = client(rec, status: 201, json: envelope(["id": "r1", "val": "x"]))
        let r = try await c.from("conformance_kv").insertForApproval(["id": K9OJSON.string("r1")]).execute()
        XCTAssertEqual(rec.last.url?.query, "requireApproval=true")
        guard case .applied(let env) = r else { return XCTFail("expected an applied write") }
        XCTAssertEqual(env.data["id"], .string("r1"))
    }

    func testUpdateSendsFlagAndQueuedCarriesTarget() async throws {
        let rec = Recorder()
        let c = client(rec, status: 202, json: queued("update", target: "r 1", payload: ["val": "n"]))
        let r = try await c.from("conformance_kv").update(["val": K9OJSON.string("n")]).eq("id", "r 1")
            .requireApproval().execute()
        XCTAssertEqual(rec.last.httpMethod, "PATCH")
        XCTAssertEqual(rec.path, "/@tasks-app/data/conformance_kv/r%201")
        XCTAssertEqual(rec.last.url?.query, "requireApproval=true")
        XCTAssertEqual(rec.lastBody as? [String: String], ["val": "n"])
        guard case .queued(let change, _) = r else { return XCTFail("expected a queued write") }
        XCTAssertEqual(change.operation, "update")
        XCTAssertEqual(change.targetRecordId, "r 1")
    }

    func testUpdateDecodesAppliedRow() async throws {
        let rec = Recorder()
        let c = client(rec, json: envelope(["id": "r1", "val": "n"]))
        let r = try await c.from("conformance_kv").update(["val": K9OJSON.string("n")]).eq("id", "r1")
            .requireApproval().execute()
        guard case .applied(let env) = r else { return XCTFail("expected an applied write") }
        XCTAssertEqual(env.data["val"], .string("n"))
    }

    func testDeleteSendsFlagWithNoBodyAndQueuedHasEmptyPayload() async throws {
        let rec = Recorder()
        let c = client(rec, status: 202, json: queued("delete", target: "r1", payload: [String: Any]()))
        let r = try await c.from("conformance_kv").delete().eq("id", "r1").requireApproval().execute()
        XCTAssertEqual(rec.last.httpMethod, "DELETE")
        XCTAssertEqual(rec.path, "/@tasks-app/data/conformance_kv/r1")
        XCTAssertEqual(rec.last.url?.query, "requireApproval=true")
        XCTAssertNil(rec.last.httpBody)
        guard case .queued(let change, _) = r else { return XCTFail("expected a queued write") }
        XCTAssertEqual(change.operation, "delete")
        XCTAssertTrue(change.proposedPayload.isEmpty)
    }

    func testDeleteDecodesAppliedAnswer() async throws {
        let rec = Recorder()
        let c = client(rec, json: envelope(["id": "r1"]))
        let r = try await c.from("conformance_kv").delete().eq("id", "r1").requireApproval().execute()
        guard case .applied = r else { return XCTFail("expected an applied write") }
    }

    func testWritesWithoutRequireApprovalSendNoQuery() async throws {
        let rec = Recorder()
        let c = client(rec, json: envelope(["id": "r1"]))
        _ = try await c.from("conformance_kv").insert(["id": K9OJSON.string("r1")])
        XCTAssertNil(rec.last.url?.query)
        _ = try await c.from("conformance_kv").update(["a": K9OJSON.number(1)]).eq("id", "r1").execute()
        XCTAssertNil(rec.last.url?.query)
        _ = try await c.from("conformance_kv").delete().eq("id", "r1").execute()
        XCTAssertNil(rec.last.url?.query)
    }

    func testRequireApprovalStillChecksIdFilterBeforeAnyRequest() async throws {
        let rec = Recorder()
        let c = client(rec, json: envelope(["id": "r1"]))
        await expectError("K9O_INVALID_FIELD_VALUE") {
            _ = try await c.from("conformance_kv").update(["a": K9OJSON.number(1)]).requireApproval().execute()
        }
        XCTAssertEqual(rec.count, 0)
    }
}
