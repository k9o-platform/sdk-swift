import XCTest
import CryptoKit
@testable import K9OCore

private struct JcsCase: Decodable {
    let name: String
    let input: K9OJSON
    let expectCanonical: String?
    let expectError: String?
}
private struct JcsCases: Decodable { let profile: String; let cases: [JcsCase] }

final class K9OJcsTests: XCTestCase {
    func testSharedCases() throws {
        let file = try JSONDecoder().decode(JcsCases.self, from: Data(jcsCasesJSON.utf8))
        XCTAssertEqual(file.profile, "kilimanjaro-jcs-code-point-v1")
        XCTAssertEqual(file.cases.count, 25)
        for c in file.cases {
            if c.expectError != nil {
                XCTAssertThrowsError(try K9OJcs.canonicalize(c.input), c.name) { XCTAssertTrue($0 is K9OJcsError) }
            } else {
                XCTAssertEqual(try K9OJcs.canonicalize(c.input), c.expectCanonical, c.name)
            }
        }
    }

    func testSortsKeysByUtf8BytesNotUtf16Units() throws {
        let v: K9OJSON = ["\u{1F600}": 1, "\u{FF5E}": 2, "\u{FB00}": 3]
        XCTAssertEqual(try K9OJcs.canonicalize(v), "{\"\u{FB00}\":3,\"\u{FF5E}\":2,\"\u{1F600}\":1}")
    }

    func testNestingEmptyContainersAndNoWhitespace() throws {
        let v: K9OJSON = ["b": [], "a": [:], "c": [1, ["z": 1, "y": nil]]]
        XCTAssertEqual(try K9OJcs.canonicalize(v), "{\"a\":{},\"b\":[],\"c\":[1,{\"y\":null,\"z\":1}]}")
    }

    func testNegativeZeroAndRefusals() throws {
        XCTAssertEqual(try K9OJcs.canonicalize(.number(-0.0)), "0")
        for n in [0.5, 1e-7, 1e21, 9007199254740992.0, -9007199254740992.0, Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try K9OJcs.canonicalize(.number(n)), "\(n)")
        }
        XCTAssertEqual(try K9OJcs.canonicalize(.number(9007199254740991)), "9007199254740991")
    }

    func testSha256Vectors() {
        XCTAssertEqual(k9oSha256Hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(k9oSha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// RFC 8032 section 7.1 test vectors 1 and 2 (empty message, one byte) against the platform Ed25519 the receipt check uses.
    func testRfc8032Ed25519Vectors() throws {
        func hex(_ s: String) -> Data {
            var d = Data(); var i = s.startIndex
            while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
            return d
        }
        let vectors: [(sk: String, pk: String, msg: String, sig: String)] = [
            ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
             "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
             "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
            ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
             "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
             "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
        ]
        for (i, v) in vectors.enumerated() {
            let sk = try Curve25519.Signing.PrivateKey(rawRepresentation: hex(v.sk))
            XCTAssertEqual(sk.publicKey.rawRepresentation, hex(v.pk), "vector \(i + 1) public key")
            // CryptoKit signs with fresh randomness, so the RFC signature is checked by verifying it, not by comparing bytes.
            let pub = try Curve25519.Signing.PublicKey(rawRepresentation: hex(v.pk))
            XCTAssertTrue(pub.isValidSignature(hex(v.sig), for: hex(v.msg)), "vector \(i + 1) verifies")
            XCTAssertTrue(sk.publicKey.isValidSignature(try sk.signature(for: hex(v.msg)), for: hex(v.msg)))
            var bad = hex(v.sig); bad[0] ^= 1
            XCTAssertFalse(sk.publicKey.isValidSignature(bad, for: hex(v.msg)), "vector \(i + 1) tampered")
        }
    }
}
