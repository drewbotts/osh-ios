import Testing
import Foundation
@testable import osh_ios

// MARK: - SWERoundTripTests
//
// The decoder is meant to be the encoder's exact inverse. These tests prove it
// on the app's own schemas by driving the real write path — the same
// buildDatastreamJSON, buildResultJSON and buildBinaryObsBody the phone posts
// with — and reading the result back.
//
// This is the check that would catch the write path and the read path drifting
// apart, which no fixture can: a fixture is a snapshot of what some other
// driver emitted, while this is what THIS app emits today.

@Suite("Round trip: decoder is the encoder's inverse")
struct SWERoundTripTests {

    /// A client instance purely to reach the nonisolated JSON builders.
    private func client() throws -> ConnectedSystemsClient {
        try ConnectedSystemsClient(nodeURL: "http://example.invalid/api",
                                   username: "u", password: "p")
    }

    /// Registers `schema` the way the app does, then decodes that registration
    /// back into a parser tree — so the schema under test is the one the node
    /// would actually have stored, not the in-memory one.
    private func decoder(for schema: DataRecord,
                         encoding: BinaryEncoding? = nil) throws -> DatastreamDecoder {
        let json = try client().buildDatastreamJSON(
            name: schema.name,
            schema: schema,
            encoding: encoding ?? BinaryEncoding(fields: []))

        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let schemaObject = try #require(root["schema"] as? [String: Any])

        let decoded = try SWESchemaDecoder.decode(
            try JSONSerialization.data(withJSONObject: schemaObject))
        return try DatastreamDecoder(datastreamId: schema.name, schema: decoded)
    }

    // MARK: Scalar round trips

    @Test("A GPS record survives buildResultJSON and comes back identical")
    func gpsRoundTrip() throws {
        let schema = GeoPosHelper.newLocationRecord(name: "gps_data",
                                                    localFrameURI: "urn:test:frame")
        let values: [Double] = [1_787_795_461.298, 34.7304, -86.5861, 183.5]

        let body = try client().buildResultJSON(schema: schema, values: values)
        let observation = try #require(try decoder(for: schema)
            .decode(json: Data(body.utf8)).first)

        #expect(observation.double(at: "/location/lat") == values[1])
        #expect(observation.double(at: "/location/lon") == values[2])
        #expect(observation.double(at: "/location/alt") == values[3])

        // The timestamp goes out as an ISO string with milliseconds, so it
        // returns quantised to the millisecond rather than bit-identical.
        #expect(abs(observation.phenomenonTime.timeIntervalSince1970 - values[0]) < 0.001)
    }

    @Test("Euler and quaternion orientation records round-trip in schema order")
    func orientationRoundTrip() throws {
        for schema in [GeoPosHelper.newEulerOrientationRecord(name: "euler",
                                                              localFrameURI: "urn:test:frame"),
                       GeoPosHelper.newQuatOrientationRecord(name: "quat",
                                                             localFrameURI: "urn:test:frame")] {
            let leaves = SchemaWalker.leafPaths(of: schema)
            // A distinct value per leaf, so a transposition cannot pass.
            let values = [1_787_795_461.298]
                + (1..<leaves.count).map { Double($0) * 1.5 - 3 }

            let body = try client().buildResultJSON(schema: schema, values: values)
            let observation = try #require(try decoder(for: schema)
                .decode(json: Data(body.utf8)).first)

            #expect(observation.orderedPaths == leaves)
            for (leaf, value) in zip(leaves.dropFirst(), values.dropFirst()) {
                #expect(observation.double(at: leaf.description) == value,
                        "\(schema.name) \(leaf)")
            }
        }
    }

    @Test("Every scalar leaf comes back in the same order it went out")
    func scalarOrderIsPreserved() throws {
        let schema = GeoPosHelper.newLocationRecord(name: "gps_data",
                                                    localFrameURI: "urn:test:frame")
        let values: [Double] = [1_787_795_461.298, 1, 2, 3]

        let body = try client().buildResultJSON(schema: schema, values: values)
        let observation = try #require(try decoder(for: schema)
            .decode(json: Data(body.utf8)).first)

        #expect(observation.orderedPaths == SchemaWalker.leafPaths(of: schema))
    }

    // MARK: Binary round trip

    @Test("A video frame survives buildBinaryObsBody and comes back byte-identical")
    func videoRoundTrip() throws {
        let (schema, encoding) = VideoCamHelper.newVideoOutputCODEC(
            name: "video", width: 1920, height: 1080, codec: "H264")

        let decoder = try decoder(for: schema, encoding: encoding)
        #expect(decoder.isBinaryBlockStream)
        #expect(decoder.blockCompression == "H264")
        #expect(decoder.preferredStreamFormat == "application/swe+binary")

        // A recognisable payload rather than zeros, so a truncation or an
        // off-by-one in the length prefix cannot pass unnoticed.
        let frame = Data((0..<5000).map { UInt8($0 % 251) })
        let timestamp = 1_787_795_461.298

        let body = try client().buildBinaryObsBody(timestamp: timestamp, frame: frame)
        let observation = try #require(try decoder.decode(binary: body).first)

        #expect(observation.orderedPaths.count == 2)
        #expect(observation.phenomenonTime.timeIntervalSince1970 == timestamp)

        guard case .block(let decoded, let compression)? = observation.value(at: "/img") else {
            Issue.record("/img should decode as a block"); return
        }
        #expect(decoded == frame)
        #expect(compression == "H264")
    }

    // MARK: The registration itself

    @Test("A registration built for the node decodes back to the same shape")
    func registrationDecodesToTheSameSchema() throws {
        let schema = GeoPosHelper.newLocationRecord(name: "gps_data",
                                                    localFrameURI: "urn:test:frame")
        let decoded = try decoder(for: schema).schema.recordSchema

        // The root record's "name" is deliberately absent from a registration
        // body — the node derives it from the datastream's outputName — so the
        // decoder has nothing to read there. Everything below the root must
        // still survive intact.
        #expect(decoded.name.isEmpty)
        #expect(decoded.fields.map(\.name) == schema.fields.map(\.name))

        let originalVector = try #require(schema.fields
            .compactMap { $0.component as? SWEVector }.first)
        let decodedVector = try #require(decoded.fields
            .compactMap { $0.component as? SWEVector }.first)
        #expect(decodedVector.coordinates.map(\.name) == originalVector.coordinates.map(\.name))
        #expect(decodedVector.refFrame == originalVector.refFrame)
    }
}
