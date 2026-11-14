import Foundation

/// Comparison operators of a `where` clause. `and`, `or` and `not` are part of the grammar, but the gateway refuses
/// them today (400 `K9O_INVALID_FIELD_VALUE` on a collection surface, `K9O_METADATA_FIELD_NOT_INDEXED` on telemetry).
public enum K9OMetadataOp: String, Sendable, Equatable, CaseIterable, Encodable {
    case eq, neq, gt, gte, lt, lte, contains, startsWith, endsWith
    case `in`, notIn, and, or, not
}

/// One condition. On a `collection:` surface `field` is a declared column (`priority` or `metadata.priority`; the
/// prefix is added when it is missing) and each field may appear once. On a `telemetry:` surface the fields are
/// `createdAt` (with `gt`, `gte`, `lt`, `lte`) and `actorId` (with `eq`).
public struct K9OMetadataWhere: Sendable, Equatable {
    public var field: String
    public var op: K9OMetadataOp
    public var value: K9OJSON?

    public init(_ field: String, _ op: K9OMetadataOp, _ value: K9OJSON? = nil) {
        self.field = field
        self.op = op
        self.value = value
    }
}

/// One result row. A `collection:` row has `recordId`; a `telemetry:` row has `eventId`. `metadata` holds the declared
/// columns that are present on the row, under their bare names (an undeclared column never appears).
public struct K9OMetadataRow: Decodable, Sendable, Equatable {
    public let surface: String
    public let scope: String
    public let recordId: String?
    public let eventId: String?
    public let metadata: [String: K9OJSON]

    private enum CodingKeys: String, CodingKey { case surface, scope, recordId, eventId, metadata }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        surface = try c.decode(String.self, forKey: .surface)
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        recordId = try c.decodeIfPresent(String.self, forKey: .recordId)
        eventId = try c.decodeIfPresent(String.self, forKey: .eventId)
        metadata = try c.decodeIfPresent([String: K9OJSON].self, forKey: .metadata) ?? [:]
    }
}

/// One declared column. `indexed` defaults to false.
public struct K9OMetadataColumn: Sendable, Equatable, Encodable {
    public var column: String
    public var indexed: Bool?

    public init(_ column: String, indexed: Bool? = nil) {
        self.column = column
        self.indexed = indexed
    }

    private enum CodingKeys: String, CodingKey { case column, indexed }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(column, forKey: .column)
        if let indexed { try c.encode(indexed, forKey: .indexed) }  // omitted when nil
    }
}

/// A collection's declaration: its declared columns, ordered by name.
public struct K9OMetadataIndex: Decodable, Sendable, Equatable {
    public struct Column: Decodable, Sendable, Equatable {
        public let column: String
        public let indexed: Bool

        public init(column: String, indexed: Bool) {
            self.column = column
            self.indexed = indexed
        }

        private enum CodingKeys: String, CodingKey { case column, indexed }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            column = try c.decode(String.self, forKey: .column)
            indexed = try c.decodeIfPresent(Bool.self, forKey: .indexed) ?? false
        }
    }

    public let collection: String
    public let columns: [Column]
}

private let metadataOps: Set<K9OMetadataOp> = Set(K9OMetadataOp.allCases)
private let metadataSlices: Set<String> = ["collection", "telemetry", "storage"]
private let metadataPrefix = "metadata."
private let metadataMaxColumns = 64
private let metadataMaxLimit = 1000
/// On a telemetry surface these where fields are sent bare, never prefixed.
private let metadataTelemetryFields: Set<String> = ["createdAt", "actorId"]

private func isAsciiLetterOrDigit(_ c: Character) -> Bool {
    guard let a = c.asciiValue else { return false }
    return (a >= 0x30 && a <= 0x39) || (a >= 0x41 && a <= 0x5A) || (a >= 0x61 && a <= 0x7A)
}

/// `^[a-zA-Z_][a-zA-Z0-9_]{0,62}$`
private func isMetadataIdent(_ s: String) -> Bool {
    guard !s.isEmpty, s.count <= 63, let first = s.first else { return false }
    guard first == "_" || (isAsciiLetterOrDigit(first) && !first.isNumber) else { return false }
    return s.allSatisfy { $0 == "_" || isAsciiLetterOrDigit($0) }
}

/// `^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`
private func isMetadataScope(_ s: String) -> Bool {
    guard !s.isEmpty, s.count <= 128, let first = s.first, isAsciiLetterOrDigit(first) else { return false }
    return s.allSatisfy { isAsciiLetterOrDigit($0) || ".:_-".contains($0) }
}

private func checkMetadataSurface(_ surface: String, _ name: String) throws {
    var slice = ""
    var scope = ""
    if let at = surface.firstIndex(of: ":") {
        slice = String(surface[surface.startIndex..<at])
        scope = String(surface[surface.index(after: at)...])
    }
    if !metadataSlices.contains(slice) || !isMetadataScope(scope) || (slice == "collection" && !isMetadataIdent(scope)) {
        throw K9OError(code: "K9O_UNKNOWN_SURFACE",
                       message: "\(name) \"\(surface)\" is not a surface: use collection:<name>, telemetry:<event> or storage:<bucket>",
                       context: .object(["surface": .string(surface)]))
    }
}

private func checkMetadataCollectionSurface(_ surface: String, _ name: String) throws {
    try checkMetadataSurface(surface, name)
    if !surface.hasPrefix("collection:") {
        throw K9OError.invalidField("\(name) must be a collection surface (collection:<name>)",
                                    context: .object(["surface": .string(surface)]))
    }
}

private func checkMetadataLimit(_ value: Int?, _ name: String) throws {
    if let value, value < 1 || value > metadataMaxLimit {
        throw K9OError.invalidField("\(name) must be a whole number from 1 to \(metadataMaxLimit)",
                                    context: .object([name: .number(Double(value))]))
    }
}

/// The name on the wire: `metadata.<name>`, adding the prefix when it is missing.
private func metadataPrefixed(_ name: String, _ label: String) throws -> String {
    if name.isEmpty || name == metadataPrefix {
        throw K9OError.invalidField("\(label) must be a column name", context: .object([label: .string(name)]))
    }
    return name.hasPrefix(metadataPrefix) ? name : metadataPrefix + name
}

private func metadataWire(_ conditions: [K9OMetadataWhere]?, telemetry: Bool) throws -> K9OJSON? {
    guard let conditions else { return nil }
    var out: [K9OJSON] = []
    for (i, c) in conditions.enumerated() {
        let bare = telemetry && metadataTelemetryFields.contains(c.field)
        var clause: [String: K9OJSON] = [
            "field": .string(bare ? c.field : try metadataPrefixed(c.field, "where[\(i)].field")),
            "op": .string(c.op.rawValue),
        ]
        if let v = c.value { clause["value"] = v }
        out.append(.object(clause))
    }
    return .array(out)
}

private func metadataCollectionName(_ collection: String) throws -> String {
    guard isMetadataIdent(collection) else {
        throw K9OError.invalidField("collection must be a collection name",
                                    context: .object(["collection": .string(collection)]))
    }
    return collection
}

private struct ColumnsBody: Encodable { let columns: [K9OMetadataColumn] }

/// `metadata`: columns you declare on a collection (or on another data surface) so they can be filtered, searched and
/// matched by vector through one API, with the same access rules as the data. `metadata` has no `subscribe`; use
/// `realtime.subscribe` for live changes.
///
/// Declare the columns first (`index.declare`). `set` writes declared columns only; `filter`, `search` and
/// `vectors.nearest` read declared columns only. Column names given to `filter` (`where` fields), `search` (`field`)
/// and `vectors.nearest` (`column`) are sent as `metadata.<name>`; the prefix is added when you leave it out. Rows come
/// back with bare column names under `metadata`. Each call returns the usual envelope; `nextCursor` holds the cursor of
/// the next page of `filter`, nil on the last page.
///
/// Errors arrive as `K9OError` with the gateway's code:
/// - 400 `K9O_UNKNOWN_SURFACE`: the surface is not `collection:<name>`, `telemetry:<event>` or `storage:<bucket>`.
/// - 400 `K9O_METADATA_FIELD_NOT_INDEXED`: the column is not declared.
/// - 400 `K9O_ENCRYPTED_COLUMN_OPERATION_UNSUPPORTED`: an encrypted column takes only `eq` (not null) and `in`.
/// - 403 `K9O_EXTENSION_PERMISSION_DENIED`: an extension token lacks a grant for the surface.
/// - 413 `K9O_QUERY_RESULT_TOO_LARGE`: more than 10000 rows across the surfaces.
/// - 501 `K9O_NOT_IMPLEMENTED`: `storage:` surfaces are accepted by the client and answered with 501.
public struct K9OMetadata: Sendable {
    let client: K9OCoreClient

    /// Nearest-vector search over a declared vector column.
    public var vectors: K9OMetadataVectors { K9OMetadataVectors(client: client) }
    /// Read and replace the declaration of a collection's metadata columns.
    public var index: K9OMetadataIndexes { K9OMetadataIndexes(client: client) }

    func path(_ tail: String) throws -> String {
        "/@\(try client.requireProject("metadata operations"))/metadata/\(tail)"
    }

    /// `POST /@<projectSlug>/metadata/query`: rows of one or more surfaces whose declared columns meet `where`, in
    /// request order. Pages with `cursor` when exactly one surface is named (`nextCursor` on the result, nil on the last
    /// page). More than 10000 rows answers 413 `K9O_QUERY_RESULT_TOO_LARGE`; a `storage:` surface answers 501
    /// `K9O_NOT_IMPLEMENTED`. `limit` is 1 to 1000 per surface (the gateway defaults to 100).
    /// Invalid input throws before any request.
    public func filter(surfaces: [String], where conditions: [K9OMetadataWhere]? = nil, limit: Int? = nil,
                       cursor: String? = nil) async throws -> K9OEnvelope<[K9OMetadataRow]> {
        let where_ = try path("query")
        if surfaces.isEmpty { throw K9OError.invalidField("surfaces must be a non-empty list") }
        for (i, s) in surfaces.enumerated() { try checkMetadataSurface(s, "surfaces[\(i)]") }
        try checkMetadataLimit(limit, "limit")
        if let cursor {
            if cursor.isEmpty { throw K9OError.invalidField("cursor must be the cursor of a previous page") }
            if surfaces.count != 1 {
                throw K9OError.invalidField("cursor is allowed only with exactly one surface",
                                            context: .object(["field": .string("cursor")]))
            }
        }
        let wire = try metadataWire(conditions, telemetry: surfaces.contains { $0.hasPrefix("telemetry:") })
        var body: [String: K9OJSON] = ["surfaces": .array(surfaces.map { .string($0) })]
        if let wire { body["where"] = wire }
        if let limit { body["limit"] = .number(Double(limit)) }
        if let cursor { body["cursor"] = .string(cursor) }
        return try await client.post(path: where_, body: K9OJSON.object(body), as: [K9OMetadataRow].self)
    }

    /// `PATCH /@<projectSlug>/metadata/collection/<collection>/<id>`: write declared columns of one record. Keys are bare
    /// column names (a leading `metadata.` is dropped); a column that is not declared answers 400
    /// `K9O_METADATA_FIELD_NOT_INDEXED`. Returns the whole updated record. The write follows the record API's rules, so a
    /// write that needs approval is queued there. Invalid input throws before any request.
    public func set(_ collection: String, id: String, _ metadata: [String: K9OJSON]) async throws -> K9OEnvelope<K9ORow> {
        let name = try metadataCollectionName(collection)
        if id.isEmpty {
            throw K9OError.invalidField("id must be a record id", context: .object(["id": .string(id)]))
        }
        if metadata.isEmpty { throw K9OError.invalidField("metadata must be a map with at least one column") }
        var bare: [String: K9OJSON] = [:]
        for (k, v) in metadata { bare[k.hasPrefix(metadataPrefix) ? String(k.dropFirst(metadataPrefix.count)) : k] = v }
        let where_ = try path("collection/\(K9OCoreClient.segmentEncode(name))/\(K9OCoreClient.segmentEncode(id))")
        return try await client.send(method: "PATCH", path: where_,
                                     body: .json(K9OJSON.object(["metadata": .object(bare)])), as: K9ORow.self)
    }

    /// `POST /@<projectSlug>/metadata/search`: full-text search over one declared text column of a collection. Matching is
    /// by word stem, so "finance" does not match "financial". Returns the first page only (there is no cursor input) and
    /// no rank. `limit` is 1 to 1000 (the gateway defaults to 50). Invalid input throws before any request.
    public func search(surface: String, field: String, q: String,
                       limit: Int? = nil) async throws -> K9OEnvelope<[K9OMetadataRow]> {
        let where_ = try path("search")
        try checkMetadataCollectionSurface(surface, "surface")
        let wireField = try metadataPrefixed(field, "field")
        if q.isEmpty { throw K9OError.invalidField("q must be a non-empty string") }
        try checkMetadataLimit(limit, "limit")
        var body: [String: K9OJSON] = ["surface": .string(surface), "field": .string(wireField), "q": .string(q)]
        if let limit { body["limit"] = .number(Double(limit)) }
        return try await client.post(path: where_, body: K9OJSON.object(body), as: [K9OMetadataRow].self)
    }
}

/// `metadata.vectors`.
public struct K9OMetadataVectors: Sendable {
    let client: K9OCoreClient

    /// `POST /@<projectSlug>/metadata/vectors/nearest`: the rows whose declared vector column is nearest to `embedding`,
    /// closest first. Rows carry no score. At most 50 rows come back whatever `k` is, until the gateway forwards a larger
    /// page size. `k` is 1 to 1000 (the gateway defaults to 10); `metric` defaults to cosine. Invalid input throws before
    /// any request.
    public func nearest(surface: String, column: String, embedding: [Double], k: Int? = nil,
                        metric: K9OVectorMetric? = nil,
                        where conditions: [K9OMetadataWhere]? = nil) async throws -> K9OEnvelope<[K9OMetadataRow]> {
        let where_ = "/@\(try client.requireProject("metadata operations"))/metadata/vectors/nearest"
        try checkMetadataCollectionSurface(surface, "surface")
        let wireColumn = try metadataPrefixed(column, "column")
        if embedding.isEmpty { throw K9OError.invalidField("embedding must be a non-empty list of numbers") }
        if embedding.contains(where: { !$0.isFinite }) {
            throw K9OError.invalidField("embedding must contain only finite numbers")
        }
        try checkMetadataLimit(k, "k")
        let wire = try metadataWire(conditions, telemetry: false)
        var body: [String: K9OJSON] = [
            "surface": .string(surface), "column": .string(wireColumn), "embedding": .array(embedding.map { .number($0) }),
        ]
        if let k { body["k"] = .number(Double(k)) }
        if let metric { body["metric"] = .string(metric.rawValue) }
        if let wire { body["where"] = wire }
        return try await client.post(path: where_, body: K9OJSON.object(body), as: [K9OMetadataRow].self)
    }
}

/// `metadata.index`.
public struct K9OMetadataIndexes: Sendable {
    let client: K9OCoreClient

    /// `GET /@<projectSlug>/metadata/index/<collection>`: the columns declared on a collection, ordered by name.
    public func get(_ collection: String) async throws -> K9OEnvelope<K9OMetadataIndex> {
        let name = try metadataCollectionName(collection)
        let slug = try client.requireProject("metadata operations")
        return try await client.send(method: "GET",
                                     path: "/@\(slug)/metadata/index/\(K9OCoreClient.segmentEncode(name))",
                                     as: K9OMetadataIndex.self)
    }

    /// `PUT /@<projectSlug>/metadata/index/<collection>`: declare the columns of a collection that metadata may use. The
    /// columns must already exist on the collection. The list replaces the previous declaration (an empty list clears
    /// it); at most 64 columns, no `id`, no duplicates. Needs the project-admin role and the migrations permission.
    /// Invalid input throws before any request.
    public func declare(_ collection: String, columns: [K9OMetadataColumn]) async throws -> K9OEnvelope<K9OMetadataIndex> {
        let name = try metadataCollectionName(collection)
        let slug = try client.requireProject("metadata operations")
        if columns.count > metadataMaxColumns {
            throw K9OError.invalidField("at most \(metadataMaxColumns) columns can be declared",
                                        context: .object(["count": .number(Double(columns.count))]))
        }
        var seen = Set<String>()
        for (i, c) in columns.enumerated() {
            if !isMetadataIdent(c.column) || c.column == "id" {
                throw K9OError.invalidField("columns[\(i)].column must be a column name other than id",
                                            context: .object(["column": .string(c.column)]))
            }
            if !seen.insert(c.column).inserted {
                throw K9OError.invalidField("column \"\(c.column)\" is listed twice",
                                            context: .object(["column": .string(c.column)]))
            }
        }
        return try await client.send(method: "PUT",
                                     path: "/@\(slug)/metadata/index/\(K9OCoreClient.segmentEncode(name))",
                                     body: .json(ColumnsBody(columns: columns)), as: K9OMetadataIndex.self)
    }
}
