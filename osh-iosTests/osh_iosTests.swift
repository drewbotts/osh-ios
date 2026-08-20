//
//  osh_iosTests.swift
//  osh-iosTests
//
//  Created by Drew Botts on 3/25/26.
//

import Foundation
import Testing
@testable import osh_ios

// MARK: - Ordered JSON output
//
// The OSH node parses SWE JSON with a Gson streaming reader that requires "type"
// to be the FIRST key of every object. Swift dictionaries do not preserve
// insertion order, which is why ConnectedSystemsClient builds these strings by
// hand — these tests are the guard rail on that invariant.

struct DatastreamJSONTests {

    /// Builds a client pointed at a dummy URL. The JSON builders are `nonisolated`
    /// and touch no network state, so no server is involved.
    private func makeClient() throws -> ConnectedSystemsClient {
        try ConnectedSystemsClient(nodeURL: "http://localhost:8181/sensorhub/api",
                                   username: "admin",
                                   password: "admin")
    }

    private func gpsModule() -> (schema: DataRecord, encoding: BinaryEncoding) {
        let schema = GeoPosHelper.newLocationRecord(
            name: "gps_data",
            localFrameURI: "urn:osh:ios:test#LOCAL_FRAME"
        )
        let encoding = BinaryEncoding(fields: [
            BinaryFieldEncoding(ref: "/time", type: .scalar(.double)),
            BinaryFieldEncoding(ref: "/location/lat", type: .scalar(.double)),
            BinaryFieldEncoding(ref: "/location/lon", type: .scalar(.double)),
            BinaryFieldEncoding(ref: "/location/alt", type: .scalar(.double))
        ])
        return (schema, encoding)
    }

    @Test func gpsDatastreamJSONIsValidAndOrdered() throws {
        let client = try makeClient()
        let gps = gpsModule()
        let json = client.buildDatastreamJSON(name: "gps_data",
                                              schema: gps.schema,
                                              encoding: gps.encoding)

        // It must be parseable at all.
        let data = try #require(json.data(using: .utf8))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(root["name"] as? String == "gps_data")
        #expect(root["outputName"] as? String == "gps_data")

        let schemaObj = try #require(root["schema"] as? [String: Any])
        // Scalar streams register as swe+json with no recordEncoding block.
        #expect(schemaObj["obsFormat"] as? String == "application/swe+json")
        #expect(schemaObj["recordEncoding"] == nil)

        let recordSchema = try #require(schemaObj["recordSchema"] as? [String: Any])
        #expect(recordSchema["type"] as? String == "DataRecord")
        // The root recordSchema omits name/label — the server derives them from outputName.
        #expect(recordSchema["name"] == nil)
        #expect(recordSchema["definition"] as? String
                == "http://sensorml.com/ont/swe/property/Location")
    }

    /// Every JSON object that carries a "type" key must carry it FIRST.
    @Test func everyTypedObjectPutsTypeFirst() throws {
        let client = try makeClient()
        let gps = gpsModule()
        let json = client.buildDatastreamJSON(name: "gps_data",
                                              schema: gps.schema,
                                              encoding: gps.encoding)

        let offenders = OrderedJSONScanner.objectsWithMisplacedType(in: json)
        #expect(offenders.isEmpty, "Objects with a non-first \"type\" key: \(offenders)")

        // Sanity check that the scanner actually found typed objects to inspect:
        // root DataRecord + time + location Vector + lat + lon + alt = 6.
        #expect(OrderedJSONScanner.typedObjectCount(in: json) == 6)
    }

    @Test func videoDatastreamJSONCarriesBinaryEncoding() throws {
        let client = try makeClient()
        let (schema, encoding) = VideoCamHelper.newVideoOutputCODEC(
            name: "camera0_H264", width: 1280, height: 720, codec: "H264")

        let json = client.buildDatastreamJSON(name: "camera0_H264",
                                              schema: schema,
                                              encoding: encoding)

        let data = try #require(json.data(using: .utf8))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let schemaObj = try #require(root["schema"] as? [String: Any])

        #expect(schemaObj["obsFormat"] as? String == "application/swe+binary")
        let recordEncoding = try #require(schemaObj["recordEncoding"] as? [String: Any])
        #expect(recordEncoding["type"] as? String == "BinaryEncoding")

        let members = try #require(recordEncoding["members"] as? [[String: Any]])
        #expect(members.count == 2)
        #expect(members[0]["type"] as? String == "Component")
        #expect(members[0]["ref"] as? String == "/time")
        #expect(members[1]["type"] as? String == "Block")
        #expect(members[1]["ref"] as? String == "/img")
        #expect(members[1]["compression"] as? String == "H264")

        // The type-first rule holds for the video schema too.
        #expect(OrderedJSONScanner.objectsWithMisplacedType(in: json).isEmpty)
    }
}

// MARK: - Timestamp formatting

struct TimestampFormattingTests {

    private func makeClient() throws -> ConnectedSystemsClient {
        try ConnectedSystemsClient(nodeURL: "http://localhost:8181/sensorhub/api",
                                   username: "admin",
                                   password: "admin")
    }

    /// Two GPS fixes inside the same second must produce distinct phenomenonTimes.
    /// Without .withFractionalSeconds the OSH node sees a duplicate timestamp and
    /// discards the second record.
    @Test func resultJSONEmitsFractionalSeconds() throws {
        let client = try makeClient()
        let schema = GeoPosHelper.newLocationRecord(
            name: "gps_data", localFrameURI: "urn:osh:ios:test#LOCAL_FRAME")

        // 2024-01-02T03:04:05.123Z
        let base = 1704164645.123
        let json = client.buildResultJSON(schema: schema,
                                          values: [base, 37.5, -122.0, 100.0])

        #expect(json.contains("\"time\":\"2024-01-02T03:04:05.123Z\""))
        #expect(json.contains("\"location\":{\"lat\":37.5,\"lon\":-122.0,\"alt\":100.0}"))
        // time comes first, exactly as the schema declares it.
        #expect(json.hasPrefix("{\"time\":"))
    }

    @Test func sameSecondTimestampsRemainDistinct() throws {
        let client = try makeClient()
        let schema = GeoPosHelper.newLocationRecord(
            name: "gps_data", localFrameURI: "urn:osh:ios:test#LOCAL_FRAME")

        let first  = client.buildResultJSON(schema: schema, values: [1704164645.001, 1, 2, 3])
        let second = client.buildResultJSON(schema: schema, values: [1704164645.999, 1, 2, 3])

        #expect(first != second)
        #expect(first.contains(".001Z"))
        #expect(second.contains(".999Z"))
    }

    @Test func wholeSecondStillCarriesMilliseconds() throws {
        let client = try makeClient()
        let schema = GeoPosHelper.newLocationRecord(
            name: "gps_data", localFrameURI: "urn:osh:ios:test#LOCAL_FRAME")

        let json = client.buildResultJSON(schema: schema, values: [1704164645.0, 1, 2, 3])
        #expect(json.contains("\"time\":\"2024-01-02T03:04:05.000Z\""))
    }
}

// MARK: - Heading normalization

struct HeadingNormalizationTests {

    /// CMAttitude.yaw is counter-clockwise radians in (-π, π]; the OSH euler
    /// output expects a clockwise compass heading in [0, 360).
    @Test(arguments: [
        (0.0,            0.0),      // north
        (-Double.pi / 2, 90.0),     // east
        (Double.pi,      180.0),    // south  (-180 wraps to 180)
        (Double.pi / 2,  270.0),    // west
    ])
    func cardinalYawsMapToCompassHeadings(yaw: Double, expected: Double) {
        let heading = EulerOrientationOutput.normalizedHeading(fromYaw: yaw)
        #expect(abs(heading - expected) < 1e-9)
    }

    @Test func headingIsAlwaysInZeroTo360() {
        // Sweep well past a full turn in both directions.
        for step in -720...720 {
            let yaw = Double(step) * .pi / 180.0
            let heading = EulerOrientationOutput.normalizedHeading(fromYaw: yaw)
            #expect(heading >= 0.0)
            #expect(heading < 360.0)
        }
    }

    @Test func negativeHeadingsWrapForward() {
        // yaw = +1 rad → -57.29…° → must come back as 302.70…°
        let heading = EulerOrientationOutput.normalizedHeading(fromYaw: 1.0)
        #expect(abs(heading - (360.0 - 180.0 / .pi)) < 1e-9)
    }

    @Test func multipleTurnsCollapseToOne() {
        let oneTurn  = EulerOrientationOutput.normalizedHeading(fromYaw: -Double.pi / 4)
        let manyTurns = EulerOrientationOutput.normalizedHeading(fromYaw: -Double.pi / 4 - 4 * .pi)
        #expect(abs(oneTurn - manyTurns) < 1e-9)
        #expect(abs(oneTurn - 45.0) < 1e-9)
    }
}

// MARK: - Ring buffer

struct RingBufferTests {

    @Test func pushAndPopAreFIFO() {
        let buffer = RingBuffer<Int>(capacity: 4)
        #expect(buffer.isEmpty)

        buffer.push(1)
        buffer.push(2)
        buffer.push(3)
        #expect(buffer.count == 3)
        #expect(!buffer.isEmpty)

        #expect(buffer.pop() == 1)
        #expect(buffer.pop() == 2)
        #expect(buffer.pop() == 3)
        #expect(buffer.pop() == nil)
        #expect(buffer.isEmpty)
    }

    @Test func overflowDropsOldest() {
        let buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.push(value) }

        // 1 and 2 were evicted; the newest three survive in order.
        #expect(buffer.count == 3)
        #expect(buffer.pop() == 3)
        #expect(buffer.pop() == 4)
        #expect(buffer.pop() == 5)
        #expect(buffer.pop() == nil)
    }

    @Test func pushFrontRequeuesAtTheHead() {
        let buffer = RingBuffer<Int>(capacity: 4)
        buffer.push(2)
        buffer.push(3)
        buffer.pushFront(1)

        #expect(buffer.count == 3)
        #expect(buffer.pop() == 1)
        #expect(buffer.pop() == 2)
        #expect(buffer.pop() == 3)
    }

    /// pushFront is the failed-send re-queue path; reversing a failed batch back
    /// into the buffer must restore its original order.
    @Test func reversedPushFrontRestoresBatchOrder() {
        let buffer = RingBuffer<Int>(capacity: 10)
        let failedBatch = [10, 11, 12]
        buffer.push(13)
        for value in failedBatch.reversed() { buffer.pushFront(value) }

        #expect(buffer.pop() == 10)
        #expect(buffer.pop() == 11)
        #expect(buffer.pop() == 12)
        #expect(buffer.pop() == 13)
    }

    @Test func pushFrontOnFullBufferIsDropped() {
        let buffer = RingBuffer<Int>(capacity: 2)
        buffer.push(1)
        buffer.push(2)
        buffer.pushFront(0)   // no room — dropped rather than evicting the tail

        #expect(buffer.count == 2)
        #expect(buffer.pop() == 1)
        #expect(buffer.pop() == 2)
    }

    @Test func wrapsAroundRepeatedly() {
        let buffer = RingBuffer<Int>(capacity: 3)
        for value in 0..<100 {
            buffer.push(value)
            #expect(buffer.pop() == value)
            #expect(buffer.isEmpty)
        }
    }

    @Test func matchesPublisherCapacity() {
        // ObservationPublisher's buffer is specified at 1000 entries.
        let buffer = RingBuffer<Int>(capacity: 1000)
        for value in 0..<1500 { buffer.push(value) }
        #expect(buffer.count == 1000)
        #expect(buffer.pop() == 500)   // first 500 evicted
    }
}

// MARK: - Ordered JSON scanner
//
// JSONSerialization throws away key order, so verifying "type comes first"
// requires walking the raw string. This is a minimal object-boundary scanner:
// for each `{`, it reads the first key and records objects whose key set
// contains "type" but whose first key is not "type".

enum OrderedJSONScanner {

    static func objectsWithMisplacedType(in json: String) -> [String] {
        scan(json).filter { $0.hasType && $0.firstKey != "type" }.map(\.firstKey)
    }

    static func typedObjectCount(in json: String) -> Int {
        scan(json).filter(\.hasType).count
    }

    private struct ObjectInfo {
        let firstKey: String
        let hasType: Bool
    }

    /// Walks the string tracking object nesting and string literals, collecting
    /// the first key and whether a "type" key appears at each object's own depth.
    private static func scan(_ json: String) -> [ObjectInfo] {
        var results: [ObjectInfo] = []
        // Per open object: (firstKey, hasType). Index in this stack == nesting depth.
        var stack: [(firstKey: String?, hasType: Bool)] = []

        let chars = Array(json)
        var index = 0
        // True when the next string literal we read is a key rather than a value.
        var expectingKey = false

        while index < chars.count {
            let char = chars[index]
            switch char {
            case "{":
                stack.append((firstKey: nil, hasType: false))
                expectingKey = true
                index += 1

            case "}":
                if let finished = stack.popLast() {
                    results.append(ObjectInfo(firstKey: finished.firstKey ?? "",
                                              hasType: finished.hasType))
                }
                expectingKey = false
                index += 1

            case ",":
                // A comma at object level introduces the next key.
                expectingKey = !stack.isEmpty
                index += 1

            case "[":
                // Array elements are values until an object opens inside them.
                expectingKey = false
                index += 1

            case "]":
                expectingKey = false
                index += 1

            case "\"":
                let (literal, next) = readString(chars, from: index)
                index = next
                if expectingKey, !stack.isEmpty {
                    let depth = stack.count - 1
                    if stack[depth].firstKey == nil { stack[depth].firstKey = literal }
                    if literal == "type" { stack[depth].hasType = true }
                    expectingKey = false
                }

            default:
                index += 1
            }
        }
        return results
    }

    /// Reads a JSON string literal starting at the opening quote.
    /// Returns the unescaped-enough contents and the index just past the closing quote.
    private static func readString(_ chars: [Character], from start: Int) -> (String, Int) {
        var index = start + 1
        var value = ""
        while index < chars.count {
            let char = chars[index]
            if char == "\\" {
                // Skip the escape and whatever it escapes.
                index += 2
                continue
            }
            if char == "\"" {
                return (value, index + 1)
            }
            value.append(char)
            index += 1
        }
        return (value, index)
    }
}
