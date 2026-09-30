import Testing
import Foundation
@testable import osh_ios

// MARK: - SurveyWriteStrategyTests
//
// The second write path: the driver's static outputs. Built from the Axis
// PTZ's real schemas (fixtures under survey-in/, captured 2026-09-15):
//
//   sensor-location-schema.json         sensorLocation: time + location{lat, lon, alt}
//   sensor-orientation-schema.json      sensorOrientation: time + orientation{heading, pitch, roll}
//   sensor-orientation-ptz-schema.json  sensorOrientationPtz: same shape, the *live* pointing — must not be chosen
//   datastreams.json                    the five datastreams as the node lists them

@Suite("Survey write strategy")
struct SurveyWriteStrategyTests {

    static let pose = SurveyedPose(latitude: 34.7250123, longitude: -86.5830456,
                                   heightAboveEllipsoid: 212.34,
                                   yaw: 217.5, pitch: 1.25, roll: -0.5)
    static let time = Date(timeIntervalSince1970: 1_789_000_000.123)

    private static func datastream(_ file: String, id: String, outputName: String) throws -> RemoteDatastream {
        let data = try FixtureLoader.requiredData(.surveyIn, file)
        let schema = try SWESchemaDecoder.decode(data)
        let summary = DatastreamSummary(id: id, name: "Axis PTZ - \(outputName)", outputName: outputName)
        return RemoteDatastream(summary: summary, schema: schema,
                                decoder: try DatastreamDecoder(datastreamId: id, schema: schema))
    }

    private static func axisLike(withPTZOrientation: Bool = true,
                                 withStaticOrientation: Bool = true) throws -> RemoteSystem {
        var streams: [RemoteDatastream] = []
        if withPTZOrientation {
            streams.append(try datastream("sensor-orientation-ptz-schema.json", id: "02odh77sm02g",
                                          outputName: "sensorOrientationPtz"))
        }
        streams.append(try datastream("sensor-location-schema.json", id: "02do9hkemgv0",
                                      outputName: "sensorLocation"))
        if withStaticOrientation {
            streams.append(try datastream("sensor-orientation-schema.json", id: "03me1lmol9i0",
                                          outputName: "sensorOrientation"))
        }
        return RemoteSystem(summary: SystemSummary(id: "02luf9f2mgag", name: "Axis PTZ"),
                            subsystems: [], datastreams: streams, controlStreams: [],
                            fixedLocation: nil)
    }

    // MARK: Detection

    @Test("The Axis PTZ writes to sensorLocation and sensorOrientation, not sensorOrientationPtz")
    func detectsAxisStaticOutputs() throws {
        let strategy = SurveyWriteStrategy.detect(for: try Self.axisLike())
        guard case .staticOutputs(let location, let orientation) = strategy else {
            Issue.record("expected staticOutputs, got \(strategy)")
            return
        }
        #expect(location.id == "02do9hkemgv0")
        #expect(orientation?.id == "03me1lmol9i0")
    }

    @Test("Only the live PTZ orientation present → location written, orientation left alone")
    func ptzOrientationAloneIsNotStatic() throws {
        let strategy = SurveyWriteStrategy.detect(for: try Self.axisLike(withStaticOrientation: false))
        guard case .staticOutputs(_, let orientation) = strategy else {
            Issue.record("expected staticOutputs, got \(strategy)")
            return
        }
        #expect(orientation == nil)
    }

    @Test("A system with no static location output gets the outputs created")
    func createOutputsWithoutStaticOutputs() throws {
        let data = try FixtureLoader.requiredData(.gps, "schema-binary.json")
        let schema = try SWESchemaDecoder.decode(data)
        let gps = RemoteDatastream(summary: DatastreamSummary(id: "gps", name: "gps_data", outputName: "gps_data"),
                                   schema: schema,
                                   decoder: try DatastreamDecoder(datastreamId: "gps", schema: schema))
        let phone = RemoteSystem(summary: SystemSummary(id: "040g", name: "iPhone"),
                                 subsystems: [], datastreams: [gps], controlStreams: [], fixedLocation: nil)
        #expect(SurveyWriteStrategy.detect(for: phone) == .createOutputs)

        let empty = RemoteSystem(summary: SystemSummary(id: "x", name: "x"),
                                 subsystems: [], datastreams: [], controlStreams: [], fixedLocation: nil)
        #expect(SurveyWriteStrategy.detect(for: empty) == .createOutputs)
    }

    // MARK: Created outputs

    /// The schemas a survey creates, registered through the same builder the
    /// publisher uses, decode to the same names, definitions and frames as the
    /// Axis driver's own outputs — so a surveyed system reads back exactly like
    /// a configured one.
    @Test("Created outputs mirror the Axis driver's sensorLocation and sensorOrientation")
    func createdOutputsMirrorDriver() throws {
        let client = try ConnectedSystemsClient(nodeURL: "http://node.invalid/sensorhub/api",
                                                username: "", password: "")
        for (record, fixture, refs) in [
            (SurveyOutputSchemas.location(), "sensor-location-schema.json",
             ["/time", "/location/lat", "/location/lon", "/location/alt"]),
            (SurveyOutputSchemas.orientation(), "sensor-orientation-schema.json",
             ["/time", "/orientation/heading", "/orientation/pitch", "/orientation/roll"])
        ] {
            let json = client.buildDatastreamJSON(name: record.name, schema: record,
                                                  encoding: SurveyOutputSchemas.scalarEncoding(refs))
            #expect(json.hasPrefix(#"{"name":"\#(record.name)","outputName":"\#(record.name)","schema":{"obsFormat":"application/swe+json","recordSchema":{"type":"DataRecord","#))

            // Decode what would be sent, through the same decoder the viewer uses.
            let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let schemaObject = try #require(root["schema"] as? [String: Any])
            let ours = try SWESchemaDecoder.decode(try JSONSerialization.data(withJSONObject: schemaObject))
            let theirs = try SWESchemaDecoder.decode(try FixtureLoader.requiredData(.surveyIn, fixture))

            let ourLeaves = SchemaWalker.leaves(of: ours.recordSchema)
            let theirLeaves = SchemaWalker.leaves(of: theirs.recordSchema)
            #expect(ourLeaves.map(\.path) == theirLeaves.map(\.path), Comment(rawValue: fixture))
            #expect(ourLeaves.map { $0.component.definition } == theirLeaves.map { $0.component.definition }, Comment(rawValue: fixture))
            #expect(ourLeaves.map { $0.component.label } == theirLeaves.map { $0.component.label }, Comment(rawValue: fixture))

            let ourVector = ours.recordSchema.fields[1].component as? SWEVector
            let theirVector = theirs.recordSchema.fields[1].component as? SWEVector
            #expect(ourVector?.definition == theirVector?.definition, Comment(rawValue: fixture))
            #expect(ourVector?.refFrame == theirVector?.refFrame, Comment(rawValue: fixture))
        }
    }

    @Test("Created outputs are recognised as static outputs on the next survey")
    func createdOutputsRoundTrip() throws {
        let client = try ConnectedSystemsClient(nodeURL: "http://node.invalid/sensorhub/api",
                                                username: "", password: "")
        func datastream(_ record: DataRecord, id: String, refs: [String]) throws -> RemoteDatastream {
            let json = client.buildDatastreamJSON(name: record.name, schema: record,
                                                  encoding: SurveyOutputSchemas.scalarEncoding(refs))
            let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let schema = try SWESchemaDecoder.decode(
                try JSONSerialization.data(withJSONObject: try #require(root["schema"] as? [String: Any])))
            return RemoteDatastream(summary: DatastreamSummary(id: id, name: record.name, outputName: record.name),
                                    schema: schema,
                                    decoder: try DatastreamDecoder(datastreamId: id, schema: schema))
        }
        let system = RemoteSystem(
            summary: SystemSummary(id: "s", name: "S"), subsystems: [],
            datastreams: [try datastream(SurveyOutputSchemas.location(), id: "loc",
                                         refs: ["/time", "/location/lat", "/location/lon", "/location/alt"]),
                          try datastream(SurveyOutputSchemas.orientation(), id: "ori",
                                         refs: ["/time", "/orientation/heading", "/orientation/pitch", "/orientation/roll"])],
            controlStreams: [], fixedLocation: nil)
        guard case .staticOutputs(let location, let orientation) = SurveyWriteStrategy.detect(for: system) else {
            Issue.record("created outputs were not recognised")
            return
        }
        #expect(location.id == "loc")
        #expect(orientation?.id == "ori")
    }

    // MARK: Bodies

    @Test("The location body follows the schema: time, then location{lat, lon, alt}")
    func locationBody() throws {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.surveyIn, "sensor-location-schema.json")).recordSchema
        let body = try SurveyObservationBody.location(schema: schema, pose: Self.pose, time: Self.time)
        #expect(body == #"{"time":"2026-09-10T00:26:40.123Z","location":{"lat":34.7250123,"lon":-86.5830456,"alt":212.34}}"#)
    }

    @Test("The orientation body follows the schema: time, then orientation{heading, pitch, roll}")
    func orientationBody() throws {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.surveyIn, "sensor-orientation-schema.json")).recordSchema
        let body = try SurveyObservationBody.orientation(schema: schema, pose: Self.pose, time: Self.time)
        #expect(body == #"{"time":"2026-09-10T00:26:40.123Z","orientation":{"heading":217.5,"pitch":1.25,"roll":-0.5}}"#)
    }

    @Test("A leaf the survey has no value for is an error, not a zero")
    func missingValue() throws {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.surveyIn, "sensor-location-schema.json")).recordSchema
        #expect(throws: SurveyObservationBody.BodyError.missingValue(path: "location/lat")) {
            try SurveyObservationBody.build(schema: schema, time: Self.time, values: ["lon": 1, "alt": 2])
        }
    }

    @Test("Bodies are what the node's own observations look like, minus the envelope")
    func matchesNodeShape() throws {
        // The node's om+json result for the same stream — same nesting and names.
        let obs = try FixtureLoader.requiredData(.surveyIn, "sensor-location-obs.json")
        let root = try #require(try JSONSerialization.jsonObject(with: obs) as? [String: Any])
        let result = try #require((root["items"] as? [[String: Any]])?.first?["result"] as? [String: Any])
        let location = try #require(result["location"] as? [String: Any])
        #expect(Set(location.keys) == ["lat", "lon", "alt"])
    }
}
