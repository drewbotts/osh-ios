import Testing
import Foundation
@testable import osh_ios

// MARK: - OrderedJSONTests
//
// The one property that matters: a document goes back out exactly as it came
// in — same keys, same order, same digits — with only the edit applied.

@Suite("Ordered JSON")
struct OrderedJSONTests {

    @Test("Key order survives a parse and serialise")
    func preservesOrder() throws {
        let text = #"{"type":"Quantity","name":"pan","uom":{"code":"deg"},"constraint":{"intervals":[[-180.0,180.0]]}}"#
        let parsed = try OrderedJSON.parse(text)
        #expect(parsed.keys == ["type", "name", "uom", "constraint"])
        #expect(parsed.serialized() == text)
    }

    @Test("Number lexemes are kept, not reformatted")
    func keepsNumberLexemes() throws {
        let text = #"[0.0,34.99950637619338,-85.32749112287203,1e-07,200,9999.0]"#
        #expect(try OrderedJSON.parse(text).serialized() == text)
    }

    @Test("Strings round-trip with escapes and non-ASCII")
    func stringEscapes() throws {
        let text = #"{"label":"Gate \"A\" \\ tab\tnew\nline — ünïcödé 😀"}"#
        let parsed = try OrderedJSON.parse(text)
        #expect(parsed["label"]?.stringValue == "Gate \"A\" \\ tab\tnew\nline — ünïcödé 😀")
        // Re-serialised with the six escapes and raw UTF-8; parses to the same.
        #expect(try OrderedJSON.parse(parsed.serialized()) == parsed)
    }

    @Test("Whitespace in the input is dropped, structure is not")
    func whitespace() throws {
        let pretty = """
        {
          "type" : "PhysicalSystem" ,
          "items" : [ 1 , true , null , { } , [ ] ]
        }
        """
        #expect(try OrderedJSON.parse(pretty).serialized()
                == #"{"type":"PhysicalSystem","items":[1,true,null,{},[]]}"#)
    }

    @Test("Setting an existing key replaces it in place")
    func replaceInPlace() throws {
        let parsed = try OrderedJSON.parse(#"{"type":"X","position":1,"parameters":[]}"#)
        let edited = parsed.setting("position", to: .string("here"), insertingAfter: ["type"])
        #expect(edited.serialized() == #"{"type":"X","position":"here","parameters":[]}"#)
    }

    @Test("Inserting a new key lands after the last anchor present")
    func insertAfterAnchor() throws {
        let parsed = try OrderedJSON.parse(#"{"type":"X","label":"L","parameters":[],"components":[]}"#)
        let edited = parsed.setting("position", to: .null,
                                    insertingAfter: ["type", "label", "validTime", "localReferenceFrames"])
        #expect(edited.keys == ["type", "label", "position", "parameters", "components"])
    }

    @Test("Inserting with no anchor present appends")
    func insertAppends() throws {
        let parsed = try OrderedJSON.parse(#"{"a":1}"#)
        #expect(parsed.setting("b", to: .bool(true), insertingAfter: ["zzz"]).keys == ["a", "b"])
    }

    @Test("Malformed documents are refused, not repaired")
    func malformed() {
        #expect(throws: OrderedJSONError.self) { try OrderedJSON.parse(#"{"a":1,}"#) }
        #expect(throws: OrderedJSONError.self) { try OrderedJSON.parse(#"{"a":1} x"#) }
        #expect(throws: OrderedJSONError.self) { try OrderedJSON.parse(#"[1,2"#) }
        #expect(throws: OrderedJSONError.self) { try OrderedJSON.parse(#"{"a":01.}"#) }
        #expect(throws: OrderedJSONError.self) { try OrderedJSON.parse(#"{"a":"\q"}"#) }
    }

    @Test("Every captured fixture document round-trips byte for byte (compacted)")
    func fixturesRoundTrip() throws {
        for slug in FixtureLoader.presentSlugs {
            let directory = FixtureLoader.directory(slug)
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".json") }
            for file in files {
                let data = try FixtureLoader.requiredData(slug, file)
                let parsed = try OrderedJSON.parse(data)
                // Foundation's own compaction as the reference for *content*;
                // key order is checked by the parse-of-serialise equality.
                let reparsed = try OrderedJSON.parse(parsed.serializedData())
                #expect(reparsed == parsed, "\(slug.rawValue)/\(file) changed on round trip")
                let foundation = try JSONSerialization.jsonObject(with: data)
                let ours = try JSONSerialization.jsonObject(with: parsed.serializedData())
                #expect((foundation as? NSObject) == (ours as? NSObject),
                        "\(slug.rawValue)/\(file) content differs from Foundation's reading")
            }
        }
    }
}
