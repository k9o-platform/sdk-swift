import Foundation

/// Where a vector came from: a source `handle` and the `chunkIndex` of the chunk within it. `extra` holds any further keys.
public struct K9OVectorSource: Codable, Sendable, Equatable {
    public let handle: String
    public let chunkIndex: Int
    public let extra: [String: K9OJSON]

    public init(handle: String, chunkIndex: Int, extra: [String: K9OJSON] = [:]) {
        self.handle = handle
        self.chunkIndex = chunkIndex
        self.extra = extra
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        handle = (try? c.decodeIfPresent(String.self, forKey: Key("handle"))) ?? ""
        chunkIndex = (try? c.decodeIfPresent(Int.self, forKey: Key("chunkIndex"))) ?? 0
        var rest: [String: K9OJSON] = [:]
        for k in c.allKeys where k.stringValue != "handle" && k.stringValue != "chunkIndex" {
            rest[k.stringValue] = try c.decode(K9OJSON.self, forKey: k)
        }
        extra = rest
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for (k, v) in extra { try c.encode(v, forKey: Key(k)) }
        try c.encode(handle, forKey: Key("handle"))
        try c.encode(chunkIndex, forKey: Key("chunkIndex"))
    }
}

/// One row to store with `vectors.upsert`.
public struct K9OVectorRow: Sendable, Equatable, Encodable {
    /// 1 to 256 characters. Default: generated. Upserting an existing id overwrites that row.
    public var id: String?
    /// 1 to 16000 numbers; every row in one request has the same length.
    public var vector: [Double]
    public var source: K9OVectorSource
    /// At most 128 characters.
    public var contentHash: String?
    /// At most 100000 characters. Stored sealed when the row belongs to a subject.
    public var text: String?
    /// Default `{}`. Only keep values here that you filter on; they are stored in plain text.
    public var metadata: [String: K9OJSON]?
    /// The one end user the row belongs to (`["eu_..."]`). Required on a per-subject collection (the default for a new
    /// collection); refused on a collection declared shared.
    public var subjectIds: [String]?

    public init(vector: [Double], source: K9OVectorSource, id: String? = nil, contentHash: String? = nil,
                text: String? = nil, metadata: [String: K9OJSON]? = nil, subjectIds: [String]? = nil) {
        self.id = id
        self.vector = vector
        self.source = source
        self.contentHash = contentHash
        self.text = text
        self.metadata = metadata
        self.subjectIds = subjectIds
    }

    private enum CodingKeys: String, CodingKey {
        case id, vector, source = "_source", contentHash, text, metadata, subjectIds
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let id { try c.encode(id, forKey: .id) }  // omitted when nil
        try c.encode(vector, forKey: .vector)
        try c.encode(source, forKey: .source)
        if let contentHash { try c.encode(contentHash, forKey: .contentHash) }
        if let text { try c.encode(text, forKey: .text) }
        if let metadata { try c.encode(metadata, forKey: .metadata) }
        if let subjectIds { try c.encode(subjectIds, forKey: .subjectIds) }
    }
}

/// One row returned by `vectors.nearest`. A higher `score` is more similar. `model` comes from `metadata.model` and
/// `chunk` from `_source.chunkIndex`, when set.
public struct K9ONearestVector: Decodable, Sendable, Equatable {
    public let id: String
    public let score: Double
    public let source: K9OVectorSource
    public let contentHash: String?
    public let text: String?
    public let metadata: [String: K9OJSON]
    public let model: String?
    public let chunk: Int?

    private enum CodingKeys: String, CodingKey { case id, score, source = "_source", contentHash, text, metadata, model, chunk }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        score = try c.decode(Double.self, forKey: .score)
        source = try c.decodeIfPresent(K9OVectorSource.self, forKey: .source) ?? K9OVectorSource(handle: "", chunkIndex: 0)
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        metadata = try c.decodeIfPresent([String: K9OJSON].self, forKey: .metadata) ?? [:]
        model = try c.decodeIfPresent(String.self, forKey: .model)
        chunk = try c.decodeIfPresent(Int.self, forKey: .chunk)
    }
}

/// Result of `vectors.nearest`: `results` closest first.
public struct K9ONearestVectorsResult: Decodable, Sendable, Equatable {
    public let results: [K9ONearestVector]
    public let collection: String
}

/// Result of `vectors.upsert`.
public struct K9OUpsertVectorsResult: Decodable, Sendable, Equatable {
    public let upserted: Int
    public let collection: String
}

private struct NearestBody: Encodable {
    let queryVector: [Double]
    let topK: Int?
    let minScore: Double?
    let metric: K9OVectorMetric?
    let filters: [String: K9OValue]?

    private enum CodingKeys: String, CodingKey { case queryVector, topK, minScore, metric, filters }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(queryVector, forKey: .queryVector)
        if let topK { try c.encode(topK, forKey: .topK) }  // omitted when nil
        if let minScore { try c.encode(minScore, forKey: .minScore) }
        if let metric { try c.encode(metric.rawValue, forKey: .metric) }
        if let filters { try c.encode(filters, forKey: .filters) }
    }
}

private struct UpsertBody: Encodable { let rows: [K9OVectorRow] }

private let maxVector = 16000
private let maxRows = 1000

private func checkVector(_ v: [Double], _ name: String) throws {
    if v.isEmpty || v.count > maxVector {
        throw K9OError.invalidField("\(name) must be a list of 1 to \(maxVector) numbers")
    }
    if v.contains(where: { !$0.isFinite }) {
        throw K9OError.invalidField("\(name) must contain only finite numbers")
    }
}

/// `vectors`: embeddings you computed yourself, stored next to the text and metadata they came from, and
/// nearest-neighbour search over them. Both calls send the vector in the request body, so they take real embeddings of
/// any common size (up to 16000 numbers).
///
/// A vector collection's name starts with `_`. The first upsert creates the collection and fixes its dimension; every
/// later vector must have the same length. Searching a collection that was never upserted answers 404
/// `K9O_COLLECTION_NOT_FOUND`.
public struct K9OVectors: Sendable {
    let client: K9OCoreClient

    func path(_ collection: String, _ tail: String) throws -> String {
        guard collection.hasPrefix("_") else {
            throw K9OError.invalidField("a vector collection name must start with _",
                                        context: .object(["collection": .string(collection)]))
        }
        let project = try client.requireProject("vectors operations")
        return "/@\(project)/vectors/\(K9OCoreClient.segmentEncode(collection))/\(tail)"
    }

    /// `POST /@<projectSlug>/vectors/<collection>/search`: the rows nearest to `queryVector`, closest first.
    ///
    /// `topK` is 1 to 1000 (the gateway defaults to 10). `minScore` keeps only results whose score is at least that.
    /// `metric` defaults to cosine. `filters` are equality checks on `id`, `contentHash`, `source.<key>` and
    /// `metadata.<key>`; every one must match. Nil options are omitted from the request.
    /// Invalid input throws `K9O_INVALID_FIELD_VALUE` before any request.
    public func nearest(_ collection: String, queryVector: [Double], topK: Int? = nil, minScore: Double? = nil,
                        metric: K9OVectorMetric? = nil,
                        filters: [String: K9OValue]? = nil) async throws -> K9OEnvelope<K9ONearestVectorsResult> {
        let where_ = try path(collection, "search")
        try checkVector(queryVector, "queryVector")
        if let topK, topK < 1 || topK > 1000 {
            throw K9OError.invalidField("topK must be a whole number from 1 to 1000",
                                        context: .object(["topK": .number(Double(topK))]))
        }
        if let minScore, !minScore.isFinite { throw K9OError.invalidField("minScore must be a number") }
        if let filters {
            for (k, v) in filters {
                if case .null = v { throw K9OError.invalidField("filter values must be a string, number or boolean",
                                                                context: .object(["filter": .string(k)])) }
                _ = try v.checked("filter value")
            }
        }
        return try await client.post(path: where_,
                                     body: NearestBody(queryVector: queryVector, topK: topK, minScore: minScore,
                                                       metric: metric, filters: filters),
                                     as: K9ONearestVectorsResult.self)
    }

    /// `POST /@<projectSlug>/vectors/<collection>/upsert`: insert or overwrite 1 to 1000 rows in one request. The first
    /// upsert creates the collection. Invalid input throws `K9O_INVALID_FIELD_VALUE` before any request.
    public func upsert(_ collection: String, rows: [K9OVectorRow]) async throws -> K9OEnvelope<K9OUpsertVectorsResult> {
        let where_ = try path(collection, "upsert")
        if rows.isEmpty || rows.count > maxRows {
            throw K9OError.invalidField("rows must be a list of 1 to \(maxRows) rows")
        }
        for (i, r) in rows.enumerated() { try checkVector(r.vector, "rows[\(i)].vector") }
        return try await client.post(path: where_, body: UpsertBody(rows: rows), as: K9OUpsertVectorsResult.self)
    }
}
