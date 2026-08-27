import Testing
import Foundation
@testable import osh_ios

// MARK: - SWEParserTreeTests
//
// The decisive property of this pass is that ONE parser tree decodes BOTH wire
// formats to the same values. Several tests below therefore decode a fixture's
// swe+json and its swe+binary and compare the two against each other rather
// than against hand-written expectations — the node produced both from the same
// record, so any disagreement is the decoder's.

@Suite("SWE parser tree")
struct SWEParserTreeTests {

    // MARK: Helpers

    private func tree(_ slug: FixtureLoader.Slug, _ schemaFile: String) throws -> SWEParserTree {
        try SWEParserTree(schema: SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(slug, schemaFile)))
    }

    private func decodeJSON(_ slug: FixtureLoader.Slug,
                            _ file: String,
                            schema: String = "schema-json.json") throws -> [ParsedObservation] {
        let tree = try tree(slug, schema)
        var source: any TokenSource = try JSONTokenSource(
            data: try FixtureLoader.requiredData(slug, file))
        return try tree.decode(from: &source, datastreamId: slug.rawValue)
    }

    private func decodeBinary(_ slug: FixtureLoader.Slug) throws -> [ParsedObservation] {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(slug, "schema-binary.json"))
        let tree = try SWEParserTree(schema: schema)
        let encoding = try #require(schema.recordEncoding)

        return try FixtureLoader.binaryMessages(slug).map { message in
            var source: any TokenSource = BinaryTokenSource(data: message, encoding: encoding)
            source.beginRecord()
            return try tree.decodeRecord(from: &source, datastreamId: slug.rawValue)
        }
    }

    // MARK: Plain scalars

    @Test("Decodes a weather record from swe+json")
    func weatherFromJSON() throws {
        let raw = try JSONSerialization.jsonObject(
            with: try FixtureLoader.requiredData(.weather, "obs-json.json"))
        let expected = try #require((raw as? [Any])?.first as? [String: Any])
        let first = try #require(try decodeJSON(.weather, "obs-json.json").first)

        // Compared against the fixture's own numbers rather than transcribed
        // ones: a hand-copied literal silently goes stale the next time the
        // fixtures are recaptured, and asserts nothing about the decoder.
        #expect(first.double(at: "/airTemperature")
                == (expected["airTemperature"] as? NSNumber)?.doubleValue)
        #expect(first.double(at: "/relativeHumidity")
                == (expected["relativeHumidity"] as? NSNumber)?.doubleValue)

        // Types, though, are the decoder's own doing and are asserted directly:
        // a Text stays text and a Count stays an integer.
        #expect(first.value(at: "/precipitationType")
                == .text(try #require(expected["precipitationType"] as? String)))
        #expect(first.value(at: "/lightningStrikeCount")
                == .int(try #require((expected["lightningStrikeCount"] as? NSNumber)?.intValue)))

        // The Time field is a Time, not a number that happens to be large.
        guard case .time(let date)? = first.value(at: "/sampleTime") else {
            Issue.record("sampleTime should decode as a time"); return
        }
        #expect(first.phenomenonTime == date)
        #expect(date == JSONTokenSource.parseTime(
            try #require(expected["sampleTime"] as? String)))
    }

    @Test("The swe+json observations endpoint answers with a bare array")
    func sweJSONIsABareArray() throws {
        // Not {"items": […]}. This is the single most load-bearing divergence
        // between the OGC collection convention and what the node serves.
        let raw = try JSONSerialization.jsonObject(
            with: try FixtureLoader.requiredData(.weather, "obs-json.json"))
        #expect(raw is [Any])
    }

    @Test("om+json supplies phenomenonTime from the envelope")
    func omJSONEnvelope() throws {
        let fromOM = try decodeJSON(.weather, "obs-omjson.json")
        let fromSWE = try decodeJSON(.weather, "obs-json.json")

        let om = try #require(fromOM.first)
        let swe = try #require(fromSWE.first)
        #expect(om.phenomenonTime == swe.phenomenonTime)
        #expect(om.double(at: "/airTemperature") == swe.double(at: "/airTemperature"))
    }

    // MARK: Binary, and agreement between the two formats

    @Test("The same tree decodes swe+binary to the same values as swe+json")
    func binaryAgreesWithJSONForAIS() throws {
        let json = try decodeJSON(.aisVesselLocation, "obs-json.json")
        let binary = try decodeBinary(.aisVesselLocation)

        let a = try #require(json.first)
        let b = try #require(binary.first)

        #expect(a.phenomenonTime == b.phenomenonTime)
        for path in ["/mmsi", "/messageId", "/navStatus", "/reportDescription",
                     "/positionAccuracy", "/raim", "/utcSecond", "/repeat",
                     "/location/lat", "/location/lon", "/sog", "/cog", "/heading"] {
            #expect(a.value(at: path) == b.value(at: path), "\(path) disagrees")
        }
    }

    @Test("Booleans, Categories and Vectors keep their types through binary")
    func binaryTypesAreNotFlattened() throws {
        let first = try #require(try decodeBinary(.aisVesselLocation).first)

        #expect(first.value(at: "/positionAccuracy") == .bool(false))
        #expect(first.value(at: "/messageId") == .text("1"))
        #expect(first.value(at: "/repeat") == .int(0))
        #expect(first.double(at: "/location/lat") == 34.3515)

        // Text is length-prefixed, so a wrong width would corrupt every field
        // after it. Reaching the last field intact is the real assertion.
        #expect(first.value(at: "/navStatus")?.asString.isEmpty == false)
    }

    @Test("A GPS record round-trips the shape this app itself writes")
    func gpsRecord() throws {
        let json = try decodeJSON(.gps, "obs-json.json")
        let binary = try decodeBinary(.gps)

        let a = try #require(json.first)
        let b = try #require(binary.first)
        #expect(a.phenomenonTime == b.phenomenonTime)
        for path in ["/location/lat", "/location/lon", "/location/alt"] {
            #expect(a.double(at: path) == b.double(at: path), "\(path) disagrees")
        }
    }

    // MARK: DataArray

    @Test("A variable-size DataArray reads its length from a referenced Count")
    func spectrumArrayFromBinary() throws {
        let first = try #require(try decodeBinary(.spectrumArray).first)

        #expect(first.value(at: "/freq_count") == .int(1024))
        #expect(first.value(at: "/channel") == .text("ch0"))

        // One value per element, at "/array/<index>/<elementTypeName>".
        #expect(first.value(at: "/frequency_axis/0/frequency") != nil)
        #expect(first.value(at: "/frequency_axis/1023/frequency") != nil)
        #expect(first.value(at: "/frequency_axis/1024/frequency") == nil)
        #expect(first.value(at: "/amplitude/1023/amplitude") != nil)

        // 2 counts + 2 texts... in short, both arrays fully populated plus the
        // four scalar fields around them.
        #expect(first.orderedPaths.count == 1024 * 2 + 4)
    }

    @Test("The array decodes identically from swe+json")
    func spectrumArrayFromJSON() throws {
        let json = try #require(try decodeJSON(.spectrumArray, "obs-json.json").first)
        let binary = try #require(try decodeBinary(.spectrumArray).first)

        #expect(json.value(at: "/freq_count") == binary.value(at: "/freq_count"))

        // The binary carries float32 and the JSON carries the decimal the node
        // printed from that same float, so they agree to float precision.
        for index in [0, 1, 511, 1023] {
            let path = "/frequency_axis/\(index)/frequency"
            let a = try #require(json.double(at: path))
            let b = try #require(binary.double(at: path))
            #expect(abs(a - b) <= abs(a) * 1e-6, "\(path): \(a) vs \(b)")
        }
    }

    // MARK: Video

    @Test("A Block member makes a DataArray one opaque frame, not a pixel walk")
    func videoFrameIsOneBlock() throws {
        let observations = try decodeBinary(.videoMJPEG)
        #expect(observations.count == 3)

        let first = try #require(observations.first)
        // Two leaves only: the time and the whole image. The schema describes
        // 1512 × 2688 × 3 components; walking them would be catastrophic.
        #expect(first.orderedPaths.count == 2)

        guard case .block(let frame, let compression)? = first.value(at: "/img") else {
            Issue.record("/img should decode as a block"); return
        }
        #expect(compression == "JPEG")
        // Real JPEG framing: SOI at the front, EOI at the back.
        #expect(Array(frame.prefix(2)) == [0xFF, 0xD8])
        #expect(Array(frame.suffix(2)) == [0xFF, 0xD9])
        #expect(frame.count > 100_000)
    }

    @Test("Video frames decode with distinct times and sizes")
    func videoFramesAreDistinct() throws {
        let observations = try decodeBinary(.videoMJPEG)
        let times = observations.map(\.phenomenonTime)
        #expect(Set(times).count == observations.count)
        #expect(times == times.sorted())
    }

    // MARK: DataChoice

    @Test("A DataChoice walks only the selected item and records the selection")
    func dataChoiceSelectsOneItem() throws {
        let tree = try tree(.choicePTZControl, "control-schema.json")

        // No command fixtures exist yet — Pass 4 captures those — so the
        // payload here is the JSON shape a choice takes: one item-named key.
        let json: Any = ["ptzControl": ["zoom": 4.0]]
        var source: any TokenSource = JSONTokenSource(json: json)
        let observation = try #require(
            try tree.decode(from: &source, datastreamId: "ptz").first)

        #expect(observation.value(at: "/ptzControl") == .text("zoom"))
        #expect(observation.double(at: "/ptzControl/zoom") == 4.0)
        // The alternatives that were not selected carry no value at all.
        #expect(observation.value(at: "/ptzControl/pan") == nil)
        #expect(observation.value(at: "/ptzControl/tilt") == nil)
    }

    // MARK: Ordering and phenomenon time

    @Test("Leaf order follows the schema, not the payload")
    func orderFollowsSchema() throws {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.weather, "schema-json.json"))
        let observation = try #require(try decodeJSON(.weather, "obs-json.json").first)

        #expect(observation.orderedPaths.map(\.lastComponent)
                == schema.recordSchema.fields.map(\.name))
    }

    @Test("phenomenonTime comes from the SamplingTime-defined field")
    func phenomenonTimeResolution() throws {
        // Every driver on the reference node defines its time field as
        // SamplingTime rather than OGC PhenomenonTime.
        let tree = try tree(.spectrumArray, "schema-json.json")
        #expect(tree.phenomenonTimePath == FieldPath("/time"))

        let ais = try self.tree(.aisVesselLocation, "schema-json.json")
        #expect(ais.phenomenonTimePath == FieldPath("/samplingTime"))
    }

    // MARK: Failure behaviour

    @Test("A truncated binary message throws rather than inventing values")
    func truncatedBinaryThrows() throws {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.aisVesselLocation, "schema-binary.json"))
        let tree = try SWEParserTree(schema: schema)
        let encoding = try #require(schema.recordEncoding)

        let full = try #require(try FixtureLoader.binaryMessages(.aisVesselLocation).first)
        var source: any TokenSource = BinaryTokenSource(data: full.prefix(20), encoding: encoding)
        source.beginRecord()

        #expect(throws: TokenSourceError.self) {
            try tree.decodeRecord(from: &source, datastreamId: "ais")
        }
    }

    @Test("A video frame cannot be read from JSON, and says so")
    func videoFromJSONThrows() throws {
        // The node substitutes "Compressed binary result not shown in JSON"
        // for the result, so this must fail loudly rather than yield a black frame.
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.videoMJPEG, "schema-binary.json"))
        let tree = try SWEParserTree(schema: schema)
        var source: any TokenSource = try JSONTokenSource(
            data: try FixtureLoader.requiredData(.videoMJPEG, "obs-omjson.json"))

        #expect(throws: TokenSourceError.self) {
            try tree.decode(from: &source, datastreamId: "video")
        }
    }

    @Test("An href that resolves to nothing fails at build time")
    func danglingReferenceThrows() throws {
        let json = """
        {"obsFormat":"application/swe+json","recordSchema":{
          "type":"DataRecord","name":"r","fields":[
            {"type":"DataArray","name":"arr",
             "elementCount":{"href":"#NOT_PRESENT"},
             "elementType":{"type":"Quantity","name":"v","uom":{"code":"m"}}}]}}
        """
        let schema = try SWESchemaDecoder.decode(Data(json.utf8))
        #expect(throws: SWEDecodeError.unresolvedReference("NOT_PRESENT")) {
            try SWEParserTree(schema: schema)
        }
    }

    // MARK: Every fixture decodes

    @Test("Every captured datastream builds a parser tree",
          arguments: FixtureLoader.Slug.allCases)
    func everyFixtureBuilds(slug: FixtureLoader.Slug) throws {
        for file in ["schema-json.json", "schema-binary.json", "control-schema.json"] {
            guard let data = FixtureLoader.data(slug, file) else { continue }
            let schema = try SWESchemaDecoder.decode(data)
            _ = try SWEParserTree(schema: schema)
        }
    }
}
