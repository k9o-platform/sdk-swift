import Foundation

// Literal syntax for `K9OJSON`, so a value reads like the JSON it stands for:
// `let input: K9OJSON = ["text": "hello", "n": 1, "tags": ["a", "b"]]`.

extension K9OJSON: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}
extension K9OJSON: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension K9OJSON: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}
extension K9OJSON: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}
extension K9OJSON: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension K9OJSON: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: K9OJSON...) { self = .array(elements) }
}
extension K9OJSON: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, K9OJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
