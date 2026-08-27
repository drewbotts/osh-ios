import Testing
import Foundation
@testable import osh_ios

// MARK: - SWESchemaDecoderTests
//
// Every assertion here is against a document a live OpenSensorHub node actually
// served (see scripts/capture-fixtures.sh). Where the SWE Common spec and the
// node's JSON disagree, these tests encode what the node does — decoding has to
// work against the deployment that exists, not the one the spec describes.

@Suite("SWE schema decoder")
struct SWESchemaDecoderTests {

    // MARK: Plain scalar record

    @Test("Decodes a plain scalar weather record")
    func decodesWeatherRecord() throws {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.weather, "schema-json.json"))

        #expect(schema.obsFormat == "application/swe+json")
        #expect(schema.recordSchema.name == "tempestOutputObservation")
        #expect(schema.recordSchema.label == "Tempest Observation")
        // swe+json carries no member table.
        #expect(schema.recordEncoding == nil)

        let fields = schema.recordSchema.fields
        #expect(fields.first?.name == "sampleTime")
        #expect(fields.first?.component is SWETime)

        let windLull = try #require(fields.first { $0.name == "windLull" })
        let quantity = try #require(windLull.component as? Quantity)
        #expect(quantity.uom == "m/s")

        // A Text field among the numbers — the decoder must not coerce it.
        let precipitation = try #require(fields.first { $0.name == "precipitationType" })
        #expect(precipitation.component is SWEText)

        let strikes = try #require(fields.first { $0.name == "lightningStrikeCount" })
        #expect(strikes.component is SWECount)
    }

    // MARK: Category, Boolean, nil values

    @Test("Decodes Category, Boolean and nilValues from an AIS record")
    func decodesAISRecord() throws {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.aisVesselLocation, "schema-json.json"))
        let fields = schema.recordSchema.fields

        let messageId = try #require(fields.first { $0.name == "messageId" })
        #expect(messageId.component is SWECategory)

        let accuracy = try #require(fields.first { $0.name == "positionAccuracy" })
        #expect(accuracy.component is SWEBoolean)

        // utcSecond declares reserved values standing for "not available" and
        // friends; losing them would let a viewer plot 60 as a real second.
        let utcSecond = try #require(fields.first { $0.name == "utcSecond" })
        let count = try #require(utcSecond.component as? SWECount)
        let nilValues = try #require(count.nilValues)
        #expect(!nilValues.isEmpty)

        // The location Vector's coordinates stay nested, not flattened.
        let location = try #require(fields.first { $0.name == "location" })
        let vector = try #require(location.component as? SWEVector)
        #expect(vector.coordinates.map(\.name) == ["lat", "lon"])
    }

    // MARK: DataArray with a referenced element count

    @Test("Resolves a DataArray elementCount href into the id index")
    func decodesSpectrumArray() throws {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.spectrumArray, "schema-json.json"))
        let fields = schema.recordSchema.fields

        // The Count that carries the real size declares an id...
        #expect(schema.idIndex["KRAKEN_FREQ_COUNT"] == FieldPath("/freq_count"))

        // ...and the array's elementCount refers to it rather than inlining a value.
        let axis = try #require(fields.first { $0.name == "frequency_axis" })
        let array = try #require(axis.component as? SWEDataArray)
        #expect(array.elementCount.ref == "KRAKEN_FREQ_COUNT")
        #expect(array.elementCount.value == nil)
        #expect(array.elementTypeName == "frequency")
        #expect(array.elementType is Quantity)
    }

    // MARK: Binary encoding

    @Test("Decodes a binary encoding's members and byte order")
    func decodesBinaryEncoding() throws {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.spectrumArray, "schema-binary.json"))

        let encoding = try #require(schema.recordEncoding)
        #expect(encoding.byteOrder == .bigEndian)
        #expect(encoding.byteEncoding == "raw")

        // The array's element type gets ONE member, at "<array>/<elementName>" —
        // a node does not write a member per index.
        let refs = encoding.members.map(\.ref)
        #expect(refs.contains("/frequency_axis/frequency"))
        #expect(!refs.contains { $0.hasPrefix("/frequency_axis/0") })

        // "string-utf-8" is the node's spelling; "utf8String" never appears.
        let channel = try #require(encoding.member(for: FieldPath("/channel")))
        guard case .component(let dataType, _, _, _) = channel.kind else {
            Issue.record("channel should be a Component member")
            return
        }
        #expect(dataType == .utf8String)
    }

    @Test("Recognises a Block member sitting at a DataArray's own path")
    func decodesVideoBlock() throws {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.videoMJPEG, "schema-binary.json"))

        let encoding = try #require(schema.recordEncoding)
        #expect(encoding.blockCompression == "JPEG")
        #expect(encoding.hasBlock(at: FieldPath("/img")))
        // The time field beside it is an ordinary scalar member.
        #expect(!encoding.hasBlock(at: FieldPath("/sampleTime")))

        // The schema still describes the full pixel structure, nested two
        // arrays deep, even though none of it is walked at decode time.
        let img = try #require(schema.recordSchema.fields.first { $0.name == "img" })
        let outer = try #require(img.component as? SWEDataArray)
        #expect(outer.elementCount.value == 1512)
        let row = try #require(outer.elementType as? SWEDataArray)
        #expect(row.elementCount.value == 2688)
        #expect(row.elementType is DataRecord)
    }

    @Test("The video datastream has no swe+json schema at all")
    func videoHasNoJSONSchema() {
        // The node answers 400 for it. Capturing that absence is the point:
        // a viewer must fall back to the binary schema rather than assume both
        // formats are always available.
        #expect(FixtureLoader.data(.videoMJPEG, "schema-json.json") == nil)
    }

    // MARK: DataChoice

    @Test("Decodes a DataChoice and its interval constraints")
    func decodesDataChoice() throws {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.choicePTZControl, "control-schema.json"))

        // A control stream's params are a bare DataChoice, so the decoder wraps
        // it in a single-field record rather than rejecting the document.
        let field = try #require(schema.recordSchema.fields.first)
        let choice = try #require(field.component as? SWEDataChoice)

        let names = choice.items.map(\.name)
        #expect(names.contains("pan"))
        #expect(names.contains("tilt"))
        #expect(names.contains("zoom"))

        let pan = try #require(choice.items.first { $0.name == "pan" })
        let quantity = try #require(pan.component as? Quantity)
        #expect(quantity.uom == "deg")
        let intervals = try #require(quantity.constraint?.intervals)
        #expect(intervals == [[-180, 180]])
    }

    // MARK: Nesting

    @Test("Decodes nested DataRecords without flattening them")
    func decodesNestedRecords() throws {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.krakenSettings, "schema-json.json"))

        let receiver = try #require(
            schema.recordSchema.fields.first { $0.name == "receiverConfigSettings" })
        let nested = try #require(receiver.component as? DataRecord)
        #expect(!nested.fields.isEmpty)
    }

    // MARK: Errors

    @Test("An unknown component type throws with its path")
    func unknownTypeThrowsWithPath() throws {
        let json = """
        {"type":"DataRecord","name":"r","fields":[
          {"type":"Quantity","name":"ok","uom":{"code":"m"}},
          {"type":"Bogus","name":"bad"}]}
        """
        #expect(throws: SWEDecodeError.unsupportedComponent("Bogus", FieldPath("/bad"))) {
            try SWESchemaDecoder.decode(Data(json.utf8))
        }
    }

    @Test("A document that is not a schema throws malformedTopLevel")
    func nonSchemaThrows() {
        #expect(throws: SWEDecodeError.self) {
            try SWESchemaDecoder.decode(Data(#"{"items":[]}"#.utf8))
        }
    }

    // MARK: dataType URI matching

    @Test("dataType URIs match on their last path component, case-insensitively")
    func dataTypeSuffixMatching() {
        #expect(SWEDataType.from(uriSuffix: "http://www.opengis.net/def/dataType/OGC/0/double") == .double)
        #expect(SWEDataType.from(uriSuffix: "double") == .double)
        #expect(SWEDataType.from(uriSuffix: "DOUBLE") == .double)
        #expect(SWEDataType.from(uriSuffix: "string-utf-8") == .utf8String)
        #expect(SWEDataType.from(uriSuffix: "boolean") == .boolean)
        #expect(SWEDataType.from(uriSuffix: "nonsense") == nil)
    }
}
