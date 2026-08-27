import Testing
import Foundation
@testable import osh_ios

// MARK: - SWEBinaryFormatTests
//
// Cases the reference node does not produce, built by hand.
//
// These matter precisely because no fixture covers them: the node emits only
// double, float32, signedInt, boolean and string-utf-8 in big-endian, so every
// other branch of BinaryTokenSource — the short and byte widths, the unsigned
// forms, little-endian, base64 framing, epoch-millis time — would otherwise
// ship untested. See BINARY_FORMAT.md for which rows have real-byte backing
// and which rest on these.

@Suite("SWE binary and JSON edge cases")
struct SWEBinaryFormatTests {

    // MARK: Builders

    private func schema(_ json: String) throws -> SWESchemaDecoder.DatastreamSchema {
        try SWESchemaDecoder.decode(Data(json.utf8))
    }

    private func decodeBinary(_ json: String, _ bytes: [UInt8]) throws -> ParsedObservation {
        let schema = try schema(json)
        let tree = try SWEParserTree(schema: schema)
        var source: any TokenSource = BinaryTokenSource(
            data: Data(bytes), encoding: try #require(schema.recordEncoding))
        source.beginRecord()
        return try tree.decodeRecord(from: &source, datastreamId: "t")
    }

    private func decodeJSON(_ schemaJSON: String, _ payload: String) throws -> [ParsedObservation] {
        let tree = try SWEParserTree(schema: try schema(schemaJSON))
        var source: any TokenSource = try JSONTokenSource(data: Data(payload.utf8))
        return try tree.decode(from: &source, datastreamId: "t")
    }

    /// A record of one Quantity, encoded with the given dataType and byte order.
    private func scalarSchema(_ dataType: String, byteOrder: String = "bigEndian") -> String {
        """
        {"obsFormat":"application/swe+binary",
         "recordSchema":{"type":"DataRecord","name":"r","fields":[
           {"type":"Quantity","name":"v","uom":{"code":"1"}}]},
         "recordEncoding":{"type":"BinaryEncoding","byteOrder":"\(byteOrder)",
           "byteEncoding":"raw","members":[
             {"type":"Component","ref":"/v","dataType":"\(dataType)"}]}}
        """
    }

    // MARK: Integer widths and signs

    @Test("Signed integer widths sign-extend")
    func signedWidths() throws {
        // -2 in each width. A missing sign extension reads as a large positive.
        #expect(try decodeBinary(scalarSchema("signedByte"), [0xFE]).double(at: "/v") == -2)
        #expect(try decodeBinary(scalarSchema("signedShort"), [0xFF, 0xFE]).double(at: "/v") == -2)
        #expect(try decodeBinary(scalarSchema("signedInt"),
                                 [0xFF, 0xFF, 0xFF, 0xFE]).double(at: "/v") == -2)
        #expect(try decodeBinary(scalarSchema("signedLong"),
                                 [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE])
                .double(at: "/v") == -2)
    }

    @Test("Unsigned integer widths do not sign-extend")
    func unsignedWidths() throws {
        #expect(try decodeBinary(scalarSchema("unsignedByte"), [0xFE]).double(at: "/v") == 254)
        #expect(try decodeBinary(scalarSchema("unsignedShort"),
                                 [0xFF, 0xFE]).double(at: "/v") == 65534)
        #expect(try decodeBinary(scalarSchema("unsignedInt"),
                                 [0xFF, 0xFF, 0xFF, 0xFE]).double(at: "/v") == 4_294_967_294)
    }

    @Test("Little-endian byte order reverses every multi-byte read")
    func littleEndian() throws {
        let big = try decodeBinary(scalarSchema("signedInt"), [0x00, 0x00, 0x01, 0x00])
        let little = try decodeBinary(scalarSchema("signedInt", byteOrder: "littleEndian"),
                                      [0x00, 0x01, 0x00, 0x00])
        #expect(big.double(at: "/v") == 256)
        #expect(little.double(at: "/v") == 256)
    }

    @Test("A float32 keeps float precision, not double garbage")
    func float32() throws {
        // 1.5 is exact in binary32: 0x3FC00000.
        #expect(try decodeBinary(scalarSchema("float32"),
                                 [0x3F, 0xC0, 0x00, 0x00]).double(at: "/v") == 1.5)
    }

    // MARK: Time

    @Test("Time is epoch seconds from a double and epoch millis from a signedLong")
    func timeUnits() throws {
        func timeSchema(_ dataType: String) -> String {
            """
            {"obsFormat":"application/swe+binary",
             "recordSchema":{"type":"DataRecord","name":"r","fields":[
               {"type":"Time","name":"t",
                "definition":"http://www.opengis.net/def/property/OGC/0/SamplingTime",
                "uom":{"href":"http://www.opengis.net/def/uom/ISO-8601/0/Gregorian"}}]},
             "recordEncoding":{"type":"BinaryEncoding","byteOrder":"bigEndian",
               "byteEncoding":"raw","members":[
                 {"type":"Component","ref":"/t","dataType":"\(dataType)"}]}}
            """
        }

        let instant = 1_787_795_461.5
        var seconds = instant.bitPattern.bigEndian
        let asDouble = try decodeBinary(timeSchema("double"),
                                        [UInt8](Data(bytes: &seconds, count: 8)))
        #expect(asDouble.phenomenonTime.timeIntervalSince1970 == instant)

        var millis = Int64(instant * 1000).bigEndian
        let asLong = try decodeBinary(timeSchema("signedLong"),
                                      [UInt8](Data(bytes: &millis, count: 8)))
        // The same instant, not one 55 years later — which is what reading
        // milliseconds as seconds would produce.
        #expect(abs(asLong.phenomenonTime.timeIntervalSince1970 - instant) < 0.001)
    }

    @Test("A JSON Time may be a number as well as an ISO string")
    func numericJSONTime() throws {
        let schemaJSON = """
        {"obsFormat":"application/swe+json",
         "recordSchema":{"type":"DataRecord","name":"r","fields":[
           {"type":"Time","name":"t",
            "definition":"http://www.opengis.net/def/property/OGC/0/SamplingTime",
            "uom":{"href":"http://www.opengis.net/def/uom/ISO-8601/0/Gregorian"}}]}}
        """
        let numeric = try #require(try decodeJSON(schemaJSON, #"{"t":1787795461.5}"#).first)
        #expect(numeric.phenomenonTime.timeIntervalSince1970 == 1_787_795_461.5)

        // Offsets and absent fractional seconds are both accepted.
        for stamp in ["2026-08-27T01:51:01.500Z",
                      "2026-08-27T01:51:01Z",
                      "2026-08-27T03:51:01+02:00"] {
            let decoded = try #require(try decodeJSON(schemaJSON, #"{"t":"\#(stamp)"}"#).first)
            #expect(decoded.phenomenonTime.timeIntervalSince1970 > 1_787_000_000)
        }
    }

    // MARK: Byte encoding

    @Test("A base64 byteEncoding is decoded before any field is read")
    func base64Message() throws {
        let json = """
        {"obsFormat":"application/swe+binary",
         "recordSchema":{"type":"DataRecord","name":"r","fields":[
           {"type":"Count","name":"n"}]},
         "recordEncoding":{"type":"BinaryEncoding","byteOrder":"bigEndian",
           "byteEncoding":"base64","members":[
             {"type":"Component","ref":"/n","dataType":"signedInt"}]}}
        """
        let schema = try schema(json)
        let tree = try SWEParserTree(schema: schema)
        let payload = Data(Data([0x00, 0x00, 0x01, 0x00]).base64EncodedString().utf8)

        var source: any TokenSource = BinaryTokenSource(
            data: payload, encoding: try #require(schema.recordEncoding))
        source.beginRecord()
        #expect(try tree.decodeRecord(from: &source, datastreamId: "t")
            .value(at: "/n") == .int(256))
    }

    // MARK: Variable arrays

    @Test("A binary DataArray reads a Count then that many elements",
          arguments: [0, 1, 4])
    func variableBinaryArray(count: Int) throws {
        let json = """
        {"obsFormat":"application/swe+binary",
         "recordSchema":{"type":"DataRecord","name":"r","fields":[
           {"type":"Count","name":"n","id":"N"},
           {"type":"DataArray","name":"arr","elementCount":{"href":"#N"},
            "elementType":{"type":"Quantity","name":"v","uom":{"code":"1"}}}]},
         "recordEncoding":{"type":"BinaryEncoding","byteOrder":"bigEndian",
           "byteEncoding":"raw","members":[
             {"type":"Component","ref":"/n","dataType":"signedInt"},
             {"type":"Component","ref":"/arr/v","dataType":"float32"}]}}
        """
        var bytes: [UInt8] = [UInt8(count >> 24 & 0xFF), UInt8(count >> 16 & 0xFF),
                              UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]
        for index in 0..<count {
            var pattern = Float(index) + 0.5
            bytes += [UInt8](Data(bytes: &pattern, count: 4)).reversed()
        }

        let observation = try decodeBinary(json, bytes)
        #expect(observation.value(at: "/n") == .int(count))
        #expect(observation.orderedPaths.count == count + 1)
        for index in 0..<count {
            #expect(observation.double(at: "/arr/\(index)/v") == Double(index) + 0.5)
        }
        // Exactly one element past the end must be absent, so an off-by-one in
        // the count would fail rather than read a neighbouring field.
        #expect(observation.value(at: "/arr/\(count)/v") == nil)
    }

    @Test("A JSON DataArray takes its length from the payload",
          arguments: [0, 1, 4])
    func variableJSONArray(count: Int) throws {
        let json = """
        {"obsFormat":"application/swe+json",
         "recordSchema":{"type":"DataRecord","name":"r","fields":[
           {"type":"Count","name":"n","id":"N"},
           {"type":"DataArray","name":"arr","elementCount":{"href":"#N"},
            "elementType":{"type":"Quantity","name":"v","uom":{"code":"1"}}}]}}
        """
        let elements = (0..<count).map { "\(Double($0) + 0.5)" }.joined(separator: ",")
        let observation = try #require(
            try decodeJSON(json, #"{"n":\#(count),"arr":[\#(elements)]}"#).first)

        #expect(observation.value(at: "/n") == .int(count))
        for index in 0..<count {
            #expect(observation.double(at: "/arr/\(index)/v") == Double(index) + 0.5)
        }
    }

    // MARK: DataChoice

    @Test("Each JSON DataChoice selection walks only its own item",
          arguments: ["a", "b", "c"])
    func jsonChoiceSelection(selected: String) throws {
        let json = """
        {"obsFormat":"application/swe+json",
         "recordSchema":{"type":"DataRecord","name":"r","fields":[
           {"type":"DataChoice","name":"c","items":[
             {"type":"Quantity","name":"a","uom":{"code":"1"}},
             {"type":"Count","name":"b"},
             {"type":"Text","name":"c"}]}]}}
        """
        let payloads = ["a": #"{"c":{"a":1.5}}"#,
                        "b": #"{"c":{"b":7}}"#,
                        "c": #"{"c":{"c":"hello"}}"#]
        let observation = try #require(try decodeJSON(json, payloads[selected]!).first)

        #expect(observation.value(at: "/c") == .text(selected))
        for other in ["a", "b", "c"] where other != selected {
            #expect(observation.value(at: "/c/\(other)") == nil)
        }
        switch selected {
        case "a": #expect(observation.value(at: "/c/a") == .double(1.5))
        case "b": #expect(observation.value(at: "/c/b") == .int(7))
        default:  #expect(observation.value(at: "/c/c") == .text("hello"))
        }
    }

    @Test("A choiceValue key alongside the selection is tolerated")
    func choiceValueKeyIsTolerated() throws {
        let json = """
        {"obsFormat":"application/swe+json",
         "recordSchema":{"type":"DataRecord","name":"r","fields":[
           {"type":"DataChoice","name":"c",
            "choiceValue":{"type":"Category","name":"sel"},
            "items":[{"type":"Quantity","name":"a","uom":{"code":"1"}},
                     {"type":"Count","name":"b"}]}]}}
        """
        let observation = try #require(
            try decodeJSON(json, #"{"c":{"choiceValue":"b","b":7}}"#).first)
        #expect(observation.value(at: "/c") == .text("b"))
        #expect(observation.value(at: "/c/b") == .int(7))
    }

    @Test("A binary DataChoice selects on a one-byte index",
          arguments: [0, 1])
    func binaryChoiceSelector(index: Int) throws {
        // UNVERIFIED against a live node — see BINARY_FORMAT.md. This pins the
        // assumed layout so that changing it is a deliberate act with a failing
        // test, not a silent drift.
        let json = """
        {"obsFormat":"application/swe+binary",
         "recordSchema":{"type":"DataRecord","name":"r","fields":[
           {"type":"DataChoice","name":"c","items":[
             {"type":"Count","name":"a"},
             {"type":"Count","name":"b"}]}]},
         "recordEncoding":{"type":"BinaryEncoding","byteOrder":"bigEndian",
           "byteEncoding":"raw","members":[
             {"type":"Component","ref":"/c/a","dataType":"signedInt"},
             {"type":"Component","ref":"/c/b","dataType":"signedInt"}]}}
        """
        let observation = try decodeBinary(json, [UInt8(index), 0x00, 0x00, 0x00, 0x09])
        #expect(observation.value(at: "/c") == .text(index == 0 ? "a" : "b"))
        #expect(observation.value(at: index == 0 ? "/c/a" : "/c/b") == .int(9))
    }

    @Test("An out-of-range choice selector throws rather than indexing off the end")
    func choiceSelectorOutOfRange() throws {
        let json = """
        {"obsFormat":"application/swe+binary",
         "recordSchema":{"type":"DataRecord","name":"r","fields":[
           {"type":"DataChoice","name":"c","items":[{"type":"Count","name":"a"}]}]},
         "recordEncoding":{"type":"BinaryEncoding","byteOrder":"bigEndian",
           "byteEncoding":"raw","members":[
             {"type":"Component","ref":"/c/a","dataType":"signedInt"}]}}
        """
        #expect(throws: SWEDecodeError.self) {
            try decodeBinary(json, [0x07, 0x00, 0x00, 0x00, 0x01])
        }
    }

    // MARK: Failure behaviour

    @Test("A truncated binary message throws with the failing path, never crashes",
          arguments: 0..<8)
    func truncationAtEveryOffset(prefix: Int) throws {
        let json = """
        {"obsFormat":"application/swe+binary",
         "recordSchema":{"type":"DataRecord","name":"r","fields":[
           {"type":"Quantity","name":"v","uom":{"code":"1"}}]},
         "recordEncoding":{"type":"BinaryEncoding","byteOrder":"bigEndian",
           "byteEncoding":"raw","members":[
             {"type":"Component","ref":"/v","dataType":"double"}]}}
        """
        // Every truncation of an 8-byte double must fail, not read past the end.
        #expect(throws: SWEDecodeError.self) {
            try decodeBinary(json, [UInt8](repeating: 0, count: prefix))
        }
    }

    @Test("A truncated text length prefix throws instead of reading past the end")
    func truncatedText() throws {
        let json = """
        {"obsFormat":"application/swe+binary",
         "recordSchema":{"type":"DataRecord","name":"r","fields":[
           {"type":"Text","name":"s"}]},
         "recordEncoding":{"type":"BinaryEncoding","byteOrder":"bigEndian",
           "byteEncoding":"raw","members":[
             {"type":"Component","ref":"/s","dataType":"string-utf-8"}]}}
        """
        // Claims 300 bytes and supplies three.
        #expect(throws: SWEDecodeError.self) {
            try decodeBinary(json, [0x01, 0x2C, 0x61, 0x62, 0x63])
        }
    }

    @Test("A missing JSON field throws naming the path that was missing")
    func missingJSONFieldNamesThePath() throws {
        let json = """
        {"obsFormat":"application/swe+json",
         "recordSchema":{"type":"DataRecord","name":"r","fields":[
           {"type":"Vector","name":"loc","coordinates":[
             {"type":"Quantity","name":"lat","uom":{"code":"deg"}},
             {"type":"Quantity","name":"lon","uom":{"code":"deg"}}]}]}}
        """
        #expect(throws: TokenSourceError.missingValue(FieldPath("/loc/lon"))) {
            try decodeJSON(json, #"{"loc":{"lat":34.7}}"#)
        }
    }

    @Test("A text field carrying a NUL round-trips through modified UTF-8")
    func modifiedUTF8NUL() throws {
        let json = """
        {"obsFormat":"application/swe+binary",
         "recordSchema":{"type":"DataRecord","name":"r","fields":[
           {"type":"Text","name":"s"}]},
         "recordEncoding":{"type":"BinaryEncoding","byteOrder":"bigEndian",
           "byteEncoding":"raw","members":[
             {"type":"Component","ref":"/s","dataType":"string-utf-8"}]}}
        """
        // Java writes NUL as C0 80, which is invalid standard UTF-8 — the
        // fallback decoder is what keeps the rest of the string readable.
        let observation = try decodeBinary(json, [0x00, 0x04, 0x61, 0xC0, 0x80, 0x62])
        #expect(observation.value(at: "/s") == .text("a\u{0}b"))
    }
}
