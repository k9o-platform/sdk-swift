import Foundation

/// Why a call was refused. The set is closed.
public enum K9OMoatReason: String, Sendable, CaseIterable {
    case roleMarker = "role_marker"
    case inputSchema = "input_schema"
    case outputSchema = "output_schema"
    case pii
}

/// Thrown when input or output is refused. `detail` is short and never repeats the refused content.
public struct K9OMoatRefusal: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public let reason: K9OMoatReason
    public let detail: String
    public init(_ reason: K9OMoatReason, _ detail: String) {
        self.reason = reason
        self.detail = detail
    }
    public var description: String { "moat refused (\(reason.rawValue)): \(detail)" }
    public var errorDescription: String? { description }
}

/// Thrown by the `K9OMoat` initialiser for an empty prompt, an unsupported schema keyword or a malformed schema.
public struct K9OMoatConfigError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "K9OMoatConfigError: \(message)" }
    public var errorDescription: String? { description }
}

/// One message of the list `K9OMoat.messages` builds.
public struct K9OMoatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user }
    public let role: Role
    public let content: String
}

/// A local guard around one model call. It runs in your process, makes no network call and needs no account.
///
/// - Pins the system prompt: `messages(_:)` builds the message list itself. Your prompt is always the one `system`
///   message and the untrusted input is always a `user` message, never a `system` one.
/// - Refuses untrusted input that carries a role or system marker (a refusal, not a sanitiser).
/// - Enforces a declared input schema and a declared output schema.
/// - Filters the output for personal data through a function you pass (optional).
///
/// The pin is structural. It stops injected text from becoming the system prompt; it does not stop that text from
/// reaching the model, so keep treating the model's answer as untrusted and check it with `checkOutput(_:)`.
///
/// Schema language: a subset of JSON Schema, written as a `K9OJSON` object. Supported keywords: `type` (object, array,
/// string, number, integer, boolean, null, or a list of them), `properties`, `required`, `additionalProperties` (true
/// or false), `items` (one schema), `enum`, `const`, `minLength`, `maxLength`, `pattern` (a regular expression,
/// searched, not anchored), `minimum`, `maximum`, `minItems`, `maxItems`. Any other keyword is rejected by the
/// initialiser, so a typo never switches a check off.
public struct K9OMoat: Sendable {
    /// Called with the output as text; return `true` when it contains personal data. A throw refuses the output.
    public typealias PiiFilter = @Sendable (String) async throws -> Bool

    private let prompt: String
    private let inputSchema: [String: K9OJSON]?
    private let outputSchema: [String: K9OJSON]?
    private let pii: PiiFilter?

    /// Throws `K9OMoatConfigError` for an empty prompt or a schema outside the supported subset.
    public init(prompt: String, inputSchema: K9OJSON? = nil, outputSchema: K9OJSON? = nil,
                pii: PiiFilter? = nil) throws {
        if prompt.isEmpty { throw K9OMoatConfigError("prompt must be a non-empty string") }
        self.inputSchema = try inputSchema.map { try Self.assertSupportedSchema($0, path: "inputSchema") }
        self.outputSchema = try outputSchema.map { try Self.assertSupportedSchema($0, path: "outputSchema") }
        self.prompt = prompt
        self.pii = pii
    }

    /// The message list for one model call: the pinned prompt as `system`, then the untrusted input as text in a
    /// `user` message (a string as it is, anything else as JSON with sorted keys).
    /// Throws `K9OMoatRefusal` (`input_schema` or `role_marker`).
    public func messages(_ untrusted: K9OJSON) throws -> [K9OMoatMessage] {
        if let schema = inputSchema, let v = Self.violation(untrusted, schema, "$") {
            throw K9OMoatRefusal(.inputSchema, v)
        }
        let text: String
        if case .string(let s) = untrusted {
            text = s
        } else {
            guard let t = Self.jsonText(untrusted) else {
                throw K9OMoatRefusal(.inputSchema, "the input cannot be written as JSON")
            }
            text = t
        }
        var found = Self.markerIn(text)
        if found == nil {
            // Object input is written as one JSON line, which hides line starts: look inside every string as well.
            var parsed = untrusted
            if case .string(let s) = untrusted, let p = Self.parseJSON(s) { parsed = p }
            found = Self.scan(parsed, depth: 0)
            if found == nil, Self.roleKeyed(parsed, depth: 0) {
                found = "contains a JSON object with a role of system, developer or assistant"
            }
        }
        if let found { throw K9OMoatRefusal(.roleMarker, found) }
        return [K9OMoatMessage(role: .system, content: prompt), K9OMoatMessage(role: .user, content: text)]
    }

    /// `messages(_:)` for a plain string.
    public func messages(_ untrusted: String) throws -> [K9OMoatMessage] {
        try messages(K9OJSON.string(untrusted))
    }

    /// Check what the model returned. Without an output schema the value is returned as it is. With one, a string is
    /// parsed as JSON first (unless the schema asks for a string) and must conform; then the PII filter, if any, sees
    /// the output as text. Returns the validated value. Throws `K9OMoatRefusal` (`output_schema` or `pii`).
    public func checkOutput(_ modelOutput: K9OJSON) async throws -> K9OJSON {
        var value = modelOutput
        if let schema = outputSchema {
            let types = Self.typeList(schema)
            let stringOnly = types.count == 1 && types[0] == "string"
            if case .string(let s) = modelOutput, !stringOnly {
                if let parsed = Self.parseJSON(s) {
                    value = parsed
                } else if !types.contains("string") {
                    throw K9OMoatRefusal(.outputSchema, "the output is not valid JSON")
                }
            }
            if let v = Self.violation(value, schema, "$") { throw K9OMoatRefusal(.outputSchema, v) }
        }
        if let pii {
            let text: String
            if case .string(let s) = value { text = s } else { text = Self.jsonText(value) ?? "" }
            let hit: Bool
            do {
                hit = try await pii(text)
            } catch {
                throw K9OMoatRefusal(.pii, "the PII filter failed, so the output is not passed")
            }
            if hit { throw K9OMoatRefusal(.pii, "the output contains personal data") }
        }
        return value
    }

    /// `checkOutput(_:)` for a plain string.
    public func checkOutput(_ modelOutput: String) async throws -> K9OJSON {
        try await checkOutput(K9OJSON.string(modelOutput))
    }

    /// Lowercase hex SHA-256 of the pinned prompt, for example to pass to Rampart as input.
    public func promptSha256() -> String { k9oSha256Hex(Data(prompt.utf8)) }

    // MARK: JSON helpers

    static func jsonText(_ v: K9OJSON) -> String? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let d = try? enc.encode(v) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func parseJSON(_ s: String) -> K9OJSON? {
        try? JSONDecoder().decode(K9OJSON.self, from: Data(s.utf8))
    }

    // MARK: schema construction rules

    private static let keywords: Set<String> = [
        "type", "properties", "required", "additionalProperties", "items", "enum", "const", "minLength", "maxLength",
        "pattern", "minimum", "maximum", "minItems", "maxItems",
    ]
    private static let types = ["object", "array", "string", "number", "integer", "boolean", "null"]

    /// Reject anything outside the subset; returns the schema's members.
    private static func assertSupportedSchema(_ schema: K9OJSON, path: String) throws -> [String: K9OJSON] {
        guard case .object(let o) = schema else { throw K9OMoatConfigError("\(path): a schema must be an object") }
        for k in o.keys.sorted() where !keywords.contains(k) {
            throw K9OMoatConfigError("\(path): unsupported schema keyword \"\(k)\"")
        }
        if let t = o["type"] {
            var list: [K9OJSON] = []
            if case .array(let a) = t { list = a } else { list = [t] }
            let ok = !list.isEmpty && list.allSatisfy { if case .string(let s) = $0 { return types.contains(s) } else { return false } }
            if !ok { throw K9OMoatConfigError("\(path): type must be one of \(types.joined(separator: ", ")) or a list of them") }
        }
        if let props = o["properties"] {
            guard case .object(let p) = props else { throw K9OMoatConfigError("\(path): properties must be an object of schemas") }
            for k in p.keys.sorted() { _ = try assertSupportedSchema(p[k]!, path: "\(path).\(k)") }
        }
        if let req = o["required"] {
            var ok = false
            if case .array(let a) = req { ok = a.allSatisfy { if case .string = $0 { return true } else { return false } } }
            if !ok { throw K9OMoatConfigError("\(path): required must be a list of property names") }
        }
        if let ap = o["additionalProperties"] {
            guard case .bool = ap else { throw K9OMoatConfigError("\(path): additionalProperties must be true or false") }
        }
        if let items = o["items"] { _ = try assertSupportedSchema(items, path: "\(path)[]") }
        if let en = o["enum"] {
            guard case .array(let a) = en, !a.isEmpty else { throw K9OMoatConfigError("\(path): enum must be a non-empty list") }
        }
        for k in ["minLength", "maxLength", "minItems", "maxItems"] {
            if let v = o[k] {
                guard case .number(let n) = v, n.isFinite, n >= 0, n == n.rounded() else {
                    throw K9OMoatConfigError("\(path): \(k) must be a non-negative integer")
                }
            }
        }
        if let pat = o["pattern"] {
            guard case .string(let s) = pat else { throw K9OMoatConfigError("\(path): pattern must be a string") }
            if (try? NSRegularExpression(pattern: s)) == nil {
                throw K9OMoatConfigError("\(path): pattern is not a valid regular expression")
            }
        }
        for k in ["minimum", "maximum"] {
            if let v = o[k] {
                guard case .number(let n) = v, n.isFinite else { throw K9OMoatConfigError("\(path): \(k) must be a finite number") }
            }
        }
        return o
    }

    // MARK: schema validation

    private static func typeList(_ schema: [String: K9OJSON]) -> [String] {
        switch schema["type"] {
        case .string(let s)?: return [s]
        case .array(let a)?: return a.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        default: return []
        }
    }

    private static func typeOf(_ v: K9OJSON) -> String {
        switch v {
        case .null: return "null"
        case .bool: return "boolean"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        case .number(let n):
            if !n.isFinite { return "other" }
            return n == n.rounded() ? "integer" : "number"
        }
    }

    private static func count(_ v: K9OJSON?) -> Int? {
        if case .number(let n)? = v { return Int(n) }
        return nil
    }

    /// The first violation of `schema` by `value` as a short message without the value, or nil when it conforms.
    private static func violation(_ value: K9OJSON, _ schema: [String: K9OJSON], _ path: String) -> String? {
        let actual = typeOf(value)
        if schema["type"] != nil {
            let list = typeList(schema)
            if !list.contains(where: { $0 == actual || ($0 == "number" && actual == "integer") }) {
                return "\(path): expected \(list.joined(separator: " or ")), got \(actual)"
            }
        }
        if let c = schema["const"], c != value { return "\(path): does not equal the required constant" }
        if case .array(let allowed)? = schema["enum"], !allowed.contains(value) {
            return "\(path): not one of the allowed values"
        }
        if case .string(let s) = value {
            let n = s.unicodeScalars.count
            if let m = count(schema["minLength"]), n < m { return "\(path): shorter than \(m)" }
            if let m = count(schema["maxLength"]), n > m { return "\(path): longer than \(m)" }
            if case .string(let pat)? = schema["pattern"] {
                let re = try? NSRegularExpression(pattern: pat)
                let range = NSRange(s.startIndex..., in: s)
                if re?.firstMatch(in: s, range: range) == nil { return "\(path): does not match the pattern" }
            }
        }
        if case .number(let n) = value {
            if case .number(let m)? = schema["minimum"], n < m { return "\(path): below \(fmt(m))" }
            if case .number(let m)? = schema["maximum"], n > m { return "\(path): above \(fmt(m))" }
        }
        if case .array(let a) = value {
            if let m = count(schema["minItems"]), a.count < m { return "\(path): fewer than \(m) items" }
            if let m = count(schema["maxItems"]), a.count > m { return "\(path): more than \(m) items" }
            if case .object(let items)? = schema["items"] {
                for (i, e) in a.enumerated() {
                    if let v = violation(e, items, "\(path)[\(i)]") { return v }
                }
            }
        }
        if case .object(let o) = value {
            if case .array(let req)? = schema["required"] {
                for r in req {
                    if case .string(let k) = r, o[k] == nil { return "\(path): missing required property \"\(k)\"" }
                }
            }
            var props: [String: K9OJSON] = [:]
            if case .object(let p)? = schema["properties"] { props = p }
            var closed = false
            if case .bool(false)? = schema["additionalProperties"] { closed = true }
            for k in o.keys.sorted() {
                if case .object(let sub)? = props[k] {
                    if let v = violation(o[k]!, sub, "\(path).\(k)") { return v }
                } else if closed {
                    return "\(path): unexpected property \"\(k)\""
                }
            }
        }
        return nil
    }

    private static func fmt(_ n: Double) -> String {
        (n == n.rounded() && abs(n) < 1e15) ? String(Int64(n)) : String(n)
    }

    // MARK: role markers

    private static let roleJson = try! NSRegularExpression(
        pattern: "\"role\"\\s*:\\s*\"\\s*(system|developer|assistant)\\s*\"")
    private static let whitespace = try! NSRegularExpression(pattern: "\\s+")
    private static let markers = ["<|system|>", "<|im_start|>", "<|im_end|>", "[inst]", "<<sys>>", "### system", "### instruction"]
    private static let lineRoles = ["system", "assistant", "developer", "tool", "user"]
    private static let badRoles: Set<String> = ["system", "developer", "assistant"]

    /// Default-ignorable and format code points, removed before any comparison (the Moat contract's table).
    private static let ignorableRanges: [ClosedRange<UInt32>] = [
        0x00AD...0x00AD, 0x034F...0x034F, 0x061C...0x061C, 0x115F...0x1160, 0x17B4...0x17B5, 0x180B...0x180F,
        0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F, 0x3164...0x3164, 0xFE00...0xFE0F, 0xFEFF...0xFEFF,
        0xFFA0...0xFFA0, 0xFFF0...0xFFF8, 0x1BCA0...0x1BCA3, 0x1D173...0x1D17A, 0xE0000...0xE0FFF,
    ]

    private static func isIgnorable(_ v: UInt32) -> Bool { ignorableRanges.contains { $0.contains(v) } }

    /// Horizontal whitespace: tab and every Unicode space separator (Zs).
    private static func isHorizontalSpace(_ u: Unicode.Scalar) -> Bool {
        u.value == 0x09 || u.properties.generalCategory == .spaceSeparator
    }

    /// Cyrillic and Greek look-alikes of the marker letters, read as the Latin letter (Moat contract, confusables
    /// version 2). Not general homoglyph detection. Applied to the comparison text only, before case-folding.
    static let confusables: [UInt32: Unicode.Scalar] = [
        0x0430: "a",
        0x0410: "a",
        0x0441: "c",
        0x0421: "c",
        0x0435: "e",
        0x0415: "e",
        0x0456: "i",
        0x0406: "i",
        0x043E: "o",
        0x041E: "o",
        0x0440: "p",
        0x0420: "p",
        0x0455: "s",
        0x0405: "s",
        0x0443: "y",
        0x0423: "y",
        0x0501: "d",
        0x04CF: "l",
        0x04C0: "l",
        0x0422: "t",
        0x041C: "m",
        0x041D: "h",
        0x0445: "x",
        0x0425: "x",
        0x0391: "a",
        0x03B1: "a",
        0x0395: "e",
        0x03B5: "e",
        0x0399: "i",
        0x03B9: "i",
        0x039F: "o",
        0x03BF: "o",
        0x03A1: "p",
        0x03C1: "p",
        0x03A4: "t",
        0x03C4: "t",
        0x03A5: "y",
        0x03C5: "u",
        0x03BD: "v",
        0x039C: "m",
        0x039D: "n",
        0x03A7: "x",
        0x03C7: "x",
        0x03F2: "c",
        0x03F9: "c",
        0x0397: "h",
        0x0442: "t",
    ]

    /// Nonspacing (Mn) and enclosing (Me) marks.
    private static func isCombiningMark(_ u: Unicode.Scalar) -> Bool {
        let c = u.properties.generalCategory
        return c == .nonspacingMark || c == .enclosingMark
    }

    /// NFKC, then NFKD with nonspacing and enclosing marks dropped, ignorable code points removed, confusables mapped
    /// to Latin, case-folded, runs of horizontal whitespace collapsed to one space. Line breaks stay. Used for matching
    /// only.
    private static func normalise(_ s: String) -> String {
        var kept = String.UnicodeScalarView()
        for u in s.precomposedStringWithCompatibilityMapping.decomposedStringWithCompatibilityMapping.unicodeScalars
        where !isCombiningMark(u) && !isIgnorable(u.value) {
            kept.append(confusables[u.value] ?? u)
        }
        var out = String.UnicodeScalarView()
        var inSpace = false
        for u in String(kept).lowercased().unicodeScalars {
            if isHorizontalSpace(u) {
                if !inSpace { out.append(" ") }
                inSpace = true
            } else {
                inSpace = false
                out.append(u)
            }
        }
        return String(out)
    }

    private static func isLineBreak(_ v: UInt32) -> Bool { v == 0x0A || v == 0x0D || v == 0x85 || v == 0x2028 || v == 0x2029 }

    /// `^[ \t]*(system|assistant|developer|tool|user)[ \t]*:` on one normalised line.
    private static func lineRole(_ line: [Unicode.Scalar]) -> String? {
        var i = 0
        while i < line.count, line[i] == " " || line[i] == "\t" { i += 1 }
        for role in lineRoles {
            let r = Array(role.unicodeScalars)
            guard i + r.count <= line.count, Array(line[i..<(i + r.count)]) == r else { continue }
            var j = i + r.count
            while j < line.count, line[j] == " " || line[j] == "\t" { j += 1 }
            if j < line.count, line[j] == ":" { return role }
        }
        return nil
    }

    private static func markerIn(_ text: String) -> String? {
        let n = normalise(text)
        var line: [Unicode.Scalar] = []
        for u in n.unicodeScalars + [Unicode.Scalar(0x0A)] {
            if isLineBreak(u.value) {
                if let r = lineRole(line) { return "a line starts with \"\(r):\"" }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(u)
            }
        }
        let flat = whitespace.stringByReplacingMatches(in: n, range: NSRange(n.startIndex..., in: n), withTemplate: " ")
        for m in markers where flat.contains(m) { return "contains the marker \(m)" }
        if roleJson.firstMatch(in: flat, range: NSRange(flat.startIndex..., in: flat)) != nil {
            return "contains a JSON object with a role of system, developer or assistant"
        }
        return nil
    }

    private static let maxDepth = 64

    /// Looks at every string value and every object key, to any depth up to 64 (deeper input is refused).
    private static func scan(_ v: K9OJSON, depth: Int) -> String? {
        if depth > maxDepth { return "the input is nested too deeply" }
        switch v {
        case .string(let s): return markerIn(s)
        case .array(let a):
            for e in a { if let r = scan(e, depth: depth + 1) { return r } }
        case .object(let o):
            for k in o.keys.sorted() {
                if let r = markerIn(k) { return r }
                if let r = scan(o[k]!, depth: depth + 1) { return r }
            }
        default: break
        }
        return nil
    }

    private static func roleKeyed(_ v: K9OJSON, depth: Int) -> Bool {
        if depth > maxDepth { return false }
        switch v {
        case .array(let a): return a.contains { roleKeyed($0, depth: depth + 1) }
        case .object(let o):
            for (k, x) in o {
                if normalise(k).trimmingCharacters(in: .whitespacesAndNewlines) == "role", case .string(let s) = x,
                   badRoles.contains(normalise(s).trimmingCharacters(in: .whitespacesAndNewlines)) { return true }
                if roleKeyed(x, depth: depth + 1) { return true }
            }
            return false
        default: return false
        }
    }
}
