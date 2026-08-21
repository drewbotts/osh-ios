import Foundation
import Testing
@testable import osh_ios

// MARK: - FieldPath
//
// FieldPath is the join between a schema leaf and a BinaryEncoding member's
// `ref`, so the two must produce identical strings for the same field.

struct FieldPathTests {

    @Test func slashStringRoundTrips() {
        let path = FieldPath("/location/lat")
        #expect(path.components == ["location", "lat"])
        #expect(path.description == "/location/lat")
        #expect(path.lastComponent == "lat")
    }

    @Test func leadingSeparatorIsOptional() {
        #expect(FieldPath("location/lat") == FieldPath("/location/lat"))
        #expect(FieldPath(components: ["location", "lat"]) == FieldPath("/location/lat"))
    }

    @Test func repeatedSeparatorsCollapse() {
        #expect(FieldPath("//location///lat/").components == ["location", "lat"])
    }

    @Test func rootPathRendersAsSingleSlash() {
        let root = FieldPath(components: [])
        #expect(root.description == "/")
        #expect(root.lastComponent == "")
    }

    @Test func appendingDescends() {
        let path = FieldPath("/location").appending("lat")
        #expect(path.description == "/location/lat")
    }

    @Test func equalPathsHashEqually() {
        var set: Set<FieldPath> = []
        set.insert(FieldPath("/time"))
        set.insert(FieldPath("time"))
        #expect(set.count == 1)
    }
}

// MARK: - SchemaWalker

struct SchemaWalkerTests {

    private static let frame = "urn:osh:ios:test#LOCAL_FRAME"

    private func gpsRecord() -> DataRecord {
        GeoPosHelper.newLocationRecord(name: "gps_data", localFrameURI: Self.frame)
    }

    // MARK: leafPaths

    @Test func gpsLeafPathsAreTimeThenLocationCoordinates() {
        let paths = SchemaWalker.leafPaths(of: gpsRecord()).map(\.description)
        #expect(paths == ["/time", "/location/lat", "/location/lon", "/location/alt"])
    }

    @Test func quaternionLeafPathsFollowSchemaOrder() {
        let record = GeoPosHelper.newQuatOrientationRecord(name: "quat_orientation_data",
                                                           localFrameURI: Self.frame)
        let paths = SchemaWalker.leafPaths(of: record).map(\.description)
        #expect(paths == ["/time", "/orient/qx", "/orient/qy", "/orient/qz", "/orient/q0"])
    }

    @Test func eulerLeafPathsFollowSchemaOrder() {
        let record = GeoPosHelper.newEulerOrientationRecord(name: "euler_orientation_data",
                                                            localFrameURI: Self.frame)
        let paths = SchemaWalker.leafPaths(of: record).map(\.description)
        #expect(paths == ["/time", "/orient/heading", "/orient/pitch", "/orient/roll"])
    }

    /// A DataArray is one leaf: the walker must not descend into the pixel
    /// structure, which no observation carries field-by-field.
    @Test func videoDataArrayIsASingleLeaf() {
        let (record, _) = VideoCamHelper.newVideoOutputCODEC(name: "camera0_H264",
                                                             width: 1280, height: 720,
                                                             codec: "H264")
        let paths = SchemaWalker.leafPaths(of: record).map(\.description)
        #expect(paths == ["/time", "/img"])
    }

    // MARK: parsedObservation — scalars

    @Test func gpsScalarsRoundTripThroughTheirPaths() throws {
        let scalars: [Double] = [1_700_000_000.25, 34.72, -86.58, 190.5]
        let parsed = try SchemaWalker.parsedObservation(datastreamId: "gps_data",
                                                        record: gpsRecord(),
                                                        scalars: scalars)

        #expect(parsed.datastreamId == "gps_data")
        #expect(parsed.orderedPaths.map(\.description)
                == ["/time", "/location/lat", "/location/lon", "/location/alt"])
        #expect(parsed.double(at: "/location/lat") == 34.72)
        #expect(parsed.double(at: "/location/lon") == -86.58)
        #expect(parsed.double(at: "/location/alt") == 190.5)
        #expect(parsed.phenomenonTime == Date(timeIntervalSince1970: 1_700_000_000.25))
    }

    /// The time field becomes .time, not .double — that is what lets the UI
    /// render it as a date without consulting the schema again.
    @Test func timeFieldIsTypedAsTime() throws {
        let parsed = try SchemaWalker.parsedObservation(
            datastreamId: "gps_data",
            record: gpsRecord(),
            scalars: [1_700_000_000, 0, 0, 0])
        #expect(parsed.value(at: "/time") == .time(Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(parsed.value(at: "/location/lat") == .double(0))
    }

    @Test func timeValueStillReadsAsEpochSeconds() throws {
        let parsed = try SchemaWalker.parsedObservation(
            datastreamId: "gps_data",
            record: gpsRecord(),
            scalars: [1_700_000_000, 0, 0, 0])
        #expect(parsed.double(at: "/time") == 1_700_000_000)
    }

    @Test func tooFewValuesThrows() {
        #expect(throws: SchemaWalkerError.valueCountMismatch(expected: 4, actual: 3)) {
            try SchemaWalker.parsedObservation(datastreamId: "gps_data",
                                               record: gpsRecord(),
                                               scalars: [1, 2, 3])
        }
    }

    @Test func tooManyValuesThrows() {
        #expect(throws: SchemaWalkerError.valueCountMismatch(expected: 4, actual: 5)) {
            try SchemaWalker.parsedObservation(datastreamId: "gps_data",
                                               record: gpsRecord(),
                                               scalars: [1, 2, 3, 4, 5])
        }
    }

    @Test func unknownPathReturnsNil() throws {
        let parsed = try SchemaWalker.parsedObservation(datastreamId: "gps_data",
                                                        record: gpsRecord(),
                                                        scalars: [1, 2, 3, 4])
        #expect(parsed.value(at: "/location/heading") == nil)
    }

    // MARK: parsedObservation — video

    @Test func videoObservationCarriesTheFrameAtTheArrayPath() throws {
        let (record, encoding) = VideoCamHelper.newVideoOutputCODEC(name: "camera0_H264",
                                                                    width: 1280, height: 720,
                                                                    codec: "H264")
        let frame = Data([0x00, 0x00, 0x00, 0x01, 0x65])
        let observation = Observation(datastreamName: "camera0_H264",
                                      payload: .video(timestamp: 1_700_000_000, frame: frame))
        let parsed = try observation.parsed(schema: record, encoding: encoding)

        #expect(parsed.orderedPaths.map(\.description) == ["/time", "/img"])
        #expect(parsed.value(at: "/img") == .block(frame, compression: "H264"))
        #expect(parsed.phenomenonTime == Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Without an encoding there is nothing that names the codec — the block
    /// still carries the bytes, just untagged.
    @Test func videoWithoutEncodingHasNoCompressionCode() throws {
        let (record, _) = VideoCamHelper.newVideoOutputCODEC(name: "camera0_H264",
                                                             width: 1280, height: 720,
                                                             codec: "H264")
        let observation = Observation(datastreamName: "camera0_H264",
                                      payload: .video(timestamp: 1, frame: Data([0x01])))
        let parsed = try observation.parsed(schema: record)
        #expect(parsed.value(at: "/img") == .block(Data([0x01]), compression: nil))
    }

    @Test func videoPayloadOnAScalarSchemaThrows() {
        let observation = Observation(datastreamName: "gps_data",
                                      payload: .video(timestamp: 1, frame: Data()))
        #expect(throws: SchemaWalkerError.noBinaryArrayField) {
            try observation.parsed(schema: gpsRecord())
        }
    }

    // MARK: Observation.parsed

    @Test func scalarObservationParsesThroughTheExtension() throws {
        let observation = Observation(datastreamName: "gps_data",
                                      payload: .scalar([1_700_000_000, 34.72, -86.58, 190.5]))
        let parsed = try observation.parsed(schema: gpsRecord())
        #expect(parsed.double(at: "/location/lat") == 34.72)
    }
}

// MARK: - FieldValue

struct FieldValueTests {

    @Test func numericCasesReadAsDouble() {
        #expect(FieldValue.double(1.5).asDouble == 1.5)
        #expect(FieldValue.int(3).asDouble == 3.0)
        #expect(FieldValue.time(Date(timeIntervalSince1970: 42)).asDouble == 42)
    }

    @Test func nonNumericCasesHaveNoDouble() {
        #expect(FieldValue.text("x").asDouble == nil)
        #expect(FieldValue.bool(true).asDouble == nil)
        #expect(FieldValue.block(Data(), compression: "H264").asDouble == nil)
    }

    @Test func blockDescribesItsCodecAndSize() {
        #expect(FieldValue.block(Data(repeating: 0, count: 12), compression: "H264").asString
                == "H264 · 12 B")
    }
}
