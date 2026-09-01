import Testing
import Foundation
@testable import osh_ios

// MARK: - DatastreamRoleTests
//
// The viewer picks its visualisations from these answers alone, so a wrong
// classification is not a cosmetic bug — it is a spectrum drawn as a table, or
// a direction-finding station with no line on the map.
//
// Every assertion here names a real captured schema. The synthetic cases exist
// only for shapes the reference node does not serve.

@Suite("Datastream role inference")
struct DatastreamRoleTests {

    private static let frame = "urn:osh:ios:test#LOCAL_FRAME"

    // MARK: Helpers

    /// The fixture's decoded schema, preferring the binary document because it
    /// is the one carrying the recordEncoding the video rule needs.
    private static func schema(_ slug: FixtureLoader.Slug) throws
        -> SWESchemaDecoder.DatastreamSchema {
        if let binary = FixtureLoader.data(slug, "schema-binary.json"),
           let decoded = try? SWESchemaDecoder.decode(binary) {
            return decoded
        }
        return try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(slug, "schema-json.json"))
    }

    /// The datastream's name as the node reports it — the status rule reads it.
    private static func datastreamName(_ slug: FixtureLoader.Slug) -> String? {
        guard let data = FixtureLoader.data(slug, "datastream.json"),
              let summary = try? JSONDecoder().decode(DatastreamSummary.self, from: data)
        else { return nil }
        return summary.name
    }

    private static func role(_ slug: FixtureLoader.Slug) throws -> DatastreamRole {
        let decoded = try schema(slug)
        return DatastreamRoleInference.role(schema: decoded.recordSchema,
                                            encoding: decoded.recordEncoding,
                                            datastreamName: datastreamName(slug))
    }

    // MARK: Fixtures

    @Test("Weather is a timeseries")
    func weatherIsTimeseries() throws {
        #expect(try Self.role(.weather) == .timeseries)
    }

    @Test("GPS is a location with no heading")
    func gpsIsLocation() throws {
        guard case .location(let paths, let heading) = try Self.role(.gps) else {
            Issue.record("expected .location, got \(try Self.role(.gps))")
            return
        }
        #expect(paths.latitude.description == "/location/lat")
        #expect(paths.longitude.description == "/location/lon")
        #expect(paths.altitude?.description == "/location/alt")
        #expect(heading == nil)
    }

    @Test("AIS vessel location is a location, rotated by true heading, keyed by MMSI")
    func aisIsMultiEntityLocation() throws {
        let decoded = try Self.schema(.aisVesselLocation)
        let role = try Self.role(.aisVesselLocation)

        guard case .location(let paths, let heading) = role else {
            Issue.record("expected .location, got \(role)")
            return
        }
        #expect(paths.latitude.description == "/location/lat")
        #expect(paths.longitude.description == "/location/lon")
        // TrueHeading, not the courseOverGround sitting right next to it: one
        // is where the hull points, the other where the ship is going.
        #expect(heading?.description == "/heading")

        let key = EntityKeyInference.entityKeyPath(schema: decoded.recordSchema, role: role)
        #expect(key?.description == "/mmsi")
    }

    @Test("Spectrum is a chart plotted against its frequency axis")
    func spectrumIsChart() throws {
        guard case .chart(let paths) = try Self.role(.spectrumArray) else {
            Issue.record("expected .chart, got \(try Self.role(.spectrumArray))")
            return
        }
        #expect(paths.xAxis?.description == "/frequency_axis")
        #expect(paths.series.map(\.description) == ["/amplitude"])
        #expect(DatastreamRoleInference.isFrequencyAxis(
            try #require(paths.xAxis), in: try Self.schema(.spectrumArray).recordSchema))
    }

    @Test("KrakenSDR settings is a status stream that reports the station's position")
    func krakenSettingsIsStatusWithPosition() throws {
        let decoded = try Self.schema(.krakenSettings)
        let role = try Self.role(.krakenSettings)
        #expect(role == .status)

        // The position is three levels down, in a record about configuration.
        // Resolving it is what puts the station on the map at all.
        let embedded = RemoteDatastream.embeddedPosition(in: decoded.recordSchema, role: role)
        let position = try #require(embedded)
        #expect(position.location.latitude.description == "/stationConfig/location/lat")
        #expect(position.location.longitude.description == "/stationConfig/location/lon")
        #expect(position.headingPath?.description == "/stationConfig/heading")
    }

    @Test("KrakenSDR DoA is a bearing, and keeps its station position separately")
    func krakenDOAIsBearing() throws {
        let decoded = try Self.schema(.krakenDOA)
        let role = try Self.role(.krakenDOA)

        guard case .bearing(let paths) = role else {
            Issue.record("expected .bearing, got \(role)")
            return
        }
        #expect(paths.angle.description == "/raw_lob")
        #expect(paths.quality?.description == "/confidence")

        // The record also carries a location vector. It must not become a
        // .location — the subject of the stream is the angle — but the position
        // has to survive, because a bearing line has to start somewhere.
        let position = try #require(
            RemoteDatastream.embeddedPosition(in: decoded.recordSchema, role: role))
        #expect(position.location.latitude.description == "/location/lat")
        #expect(position.headingPath == nil)

        // Multi-entity grouping is for locations; a DOA stream's `uuid` names
        // the station, not one of many tracked things.
        #expect(EntityKeyInference.entityKeyPath(schema: decoded.recordSchema, role: role) == nil)
    }

    @Test("The laser range finder's target output is a target, not a location")
    func lrfTargetIsTarget() throws {
        let decoded = try Self.schema(.lrfTarget)
        let role = try Self.role(.lrfTarget)

        guard case .target(let paths) = role else {
            Issue.record("expected .target, got \(role)")
            return
        }
        #expect(paths.location.latitude.description == "/location/lat")
        #expect(paths.location.longitude.description == "/location/lon")
        #expect(paths.location.altitude?.description == "/location/alt")

        // The reference node splits the range finder's output in two: the point
        // here, the numbers on a sibling datastream. So every one of these is
        // nil, and the card and the marker have to cope with that.
        #expect(paths.range == nil)
        #expect(paths.azimuth == nil)
        #expect(paths.elevation == nil)
        #expect(paths.sourceIdPath == nil)

        // The whole point of the role. Treating the target's coordinates as an
        // embedded position would pin the range finder on top of the thing it
        // was pointing at, which is the bug this fixes.
        #expect(RemoteDatastream.embeddedPosition(in: decoded.recordSchema, role: role) == nil)
    }

    @Test("The same range finder's range output stays a bearing")
    func lrfRangeIsBearing() throws {
        let role = try Self.role(.lrfRange)
        guard case .bearing(let paths) = role else {
            Issue.record("expected .bearing, got \(role)")
            return
        }
        // An azimuth and two distances, and no location vector anywhere: rule 2
        // must not fire, and rule 5 must.
        #expect(paths.angle.description == "/azimuth")
    }

    @Test("MJPEG video is video, with the node's compression code")
    func videoIsVideo() throws {
        #expect(try Self.role(.videoMJPEG) == .video(compression: "JPEG"))
    }

    // MARK: This app's own schemas

    @Test("The app's own GPS record is a location")
    func ownGPSIsLocation() {
        let schema = GeoPosHelper.newLocationRecord(name: "gps_data", localFrameURI: Self.frame)
        guard case .location(let paths, let heading) =
                DatastreamRoleInference.role(schema: schema) else {
            Issue.record("expected .location")
            return
        }
        #expect(paths.latitude.description == "/location/lat")
        #expect(heading == nil)
    }

    @Test("The app's own quaternion record is an orientation")
    func ownQuaternionIsOrientation() {
        let schema = GeoPosHelper.newQuatOrientationRecord(name: "quat_orientation_data",
                                                           localFrameURI: Self.frame)
        guard case .orientation(let paths) = DatastreamRoleInference.role(schema: schema),
              case .quaternion(let x, let y, let z, let w) = paths.kind else {
            Issue.record("expected .orientation(.quaternion)")
            return
        }
        #expect(x.description == "/orient/qx")
        #expect(y.description == "/orient/qy")
        #expect(z.description == "/orient/qz")
        #expect(w.description == "/orient/q0")
    }

    @Test("The app's own Euler record is an orientation with pitch and roll")
    func ownEulerIsOrientation() {
        let schema = GeoPosHelper.newEulerOrientationRecord(name: "euler_orientation_data",
                                                            localFrameURI: Self.frame)
        guard case .orientation(let paths) = DatastreamRoleInference.role(schema: schema),
              case .euler(let heading, let pitch, let roll) = paths.kind else {
            Issue.record("expected .orientation(.euler)")
            return
        }
        #expect(heading.description == "/orient/heading")
        #expect(pitch?.description == "/orient/pitch")
        #expect(roll?.description == "/orient/roll")
    }

    @Test("The app's own video record is video once its encoding is read")
    func ownVideoIsVideo() {
        let (schema, encoding) = VideoCamHelper.newVideoOutputCODEC(name: "camera0_H264",
                                                                    width: 1280, height: 720,
                                                                    codec: "H264")
        let role = DatastreamRoleInference.role(schema: schema,
                                                encoding: DecodedBinaryEncoding(encoding))
        #expect(role == .video(compression: "H264"))
    }

    // MARK: Synthetic shapes the node does not serve

    @Test("A Euler-only record with no position is still an orientation")
    func syntheticEulerOnly() {
        let schema = DataRecord(
            definition: "http://sensorml.com/ont/swe/property/EulerAngles",
            label: "Attitude",
            name: "attitude",
            fields: [
                DataField(name: "time", component: TimeStamp()),
                DataField(name: "yaw", component: Quantity(
                    definition: "http://sensorml.com/ont/swe/property/HeadingAngle",
                    label: "Yaw", uom: "deg")),
                DataField(name: "pitch", component: Quantity(
                    definition: "http://sensorml.com/ont/swe/property/PitchAngle",
                    label: "Pitch", uom: "deg")),
                DataField(name: "roll", component: Quantity(
                    definition: "http://sensorml.com/ont/swe/property/RollAngle",
                    label: "Roll", uom: "deg"))
            ])

        guard case .orientation(let paths) = DatastreamRoleInference.role(schema: schema),
              case .euler(let heading, let pitch, let roll) = paths.kind else {
            Issue.record("expected .orientation(.euler)")
            return
        }
        #expect(heading.description == "/yaw")
        #expect(pitch?.description == "/pitch")
        #expect(roll?.description == "/roll")
    }

    @Test("A DOA record named nothing like a bearing is still a bearing by definition")
    func syntheticDOA() {
        let schema = DataRecord(
            definition: "http://sensorml.com/ont/swe/property/doaOutput",
            label: "DoA",
            name: "doa",
            fields: [
                DataField(name: "time", component: TimeStamp()),
                DataField(name: "rawLOB", component: Quantity(
                    definition: "http://sensorml.com/ont/swe/property/DOAAngle",
                    label: "Raw LOB", uom: "deg")),
                DataField(name: "confidence", component: Quantity(
                    definition: "http://sensorml.com/ont/swe/property/ConfidenceValue",
                    label: "Confidence", uom: "1"))
            ])

        guard case .bearing(let paths) = DatastreamRoleInference.role(schema: schema) else {
            Issue.record("expected .bearing")
            return
        }
        #expect(paths.angle.description == "/rawLOB")
        #expect(paths.quality?.description == "/confidence")
    }

    /// "lob" and "doa" are short enough to appear inside ordinary words, so the
    /// matcher splits identifiers into tokens rather than scanning substrings.
    @Test("Short bearing keywords do not fire on words that merely contain them")
    func shortKeywordsNeedWholeTokens() {
        // "globe" contains "lob" and "payload" contains "aoa" nowhere near a
        // bearing; substring matching would classify this as direction finding.
        let schema = DataRecord(
            definition: "http://sensorml.com/ont/swe/property/GlobeGeometry",
            label: "Globe",
            name: "globe",
            fields: [
                DataField(name: "time", component: TimeStamp()),
                DataField(name: "globeRadius", component: Quantity(
                    definition: "http://sensorml.com/ont/swe/property/GlobeRadius",
                    label: "Globe radius", uom: "m"))
            ])
        #expect(DatastreamRoleInference.role(schema: schema) == .timeseries)
    }

    @Test("A record with no time and no numbers falls through to generic")
    func genericFallback() {
        let schema = DataRecord(definition: nil, label: "Notes", name: "notes",
                                fields: [
                                    DataField(name: "note", component: SWEText(label: "Note"))
                                ])
        #expect(DatastreamRoleInference.role(schema: schema) == .generic)
    }

    // MARK: Target detection, and what it must not swallow

    /// A record whose location vector says nothing about targets but which
    /// carries a range beside it. The sibling range is the second half of
    /// rule 2, and this is the shape it exists for.
    @Test("A location vector with a range beside it is a target")
    func syntheticTargetByRange() {
        let schema = DataRecord(
            definition: "http://sensorml.com/ont/swe/property/RangeFinderOutput",
            label: "Designation", name: "designation",
            fields: [
                DataField(name: "time", component: TimeStamp()),
                DataField(name: "observerUid", component: SWEText(
                    definition: "http://sensorml.com/ont/swe/property/SourceSystemUID",
                    label: "Source System UID")),
                DataField(name: "location", component: SWEVector(
                    definition: "http://sensorml.com/ont/swe/property/PointLocation",
                    label: "Point",
                    coordinates: [
                        DataField(name: "lat", component: Quantity(
                            definition: "http://sensorml.com/ont/swe/property/GeodeticLatitude",
                            label: "Lat", uom: "deg")),
                        DataField(name: "lon", component: Quantity(
                            definition: "http://sensorml.com/ont/swe/property/Longitude",
                            label: "Lon", uom: "deg"))
                    ])),
                DataField(name: "slantRange", component: Quantity(
                    definition: "http://qudt.org/vocab/quantitykind/Distance",
                    label: "Slant Range", uom: "m")),
                DataField(name: "azimuth", component: Quantity(
                    definition: "http://sensorml.com/ont/swe/property/AzimuthAngle",
                    label: "Azimuth", uom: "deg")),
                DataField(name: "inclination", component: Quantity(
                    definition: "http://sensorml.com/ont/swe/property/ElevationAngle",
                    label: "Inclination", uom: "deg"))
            ])

        guard case .target(let paths) = DatastreamRoleInference.role(schema: schema) else {
            Issue.record("expected .target")
            return
        }
        #expect(paths.range?.description == "/slantRange")
        #expect(paths.azimuth?.description == "/azimuth")
        #expect(paths.elevation?.description == "/inclination")
        #expect(paths.sourceIdPath?.description == "/observerUid")
    }

    /// The exclusion that keeps direction finding working. A record with an
    /// azimuth and no location vector is a line of bearing, and rule 2 running
    /// first must not change that.
    @Test("A record with an azimuth but no location vector is a bearing, not a target")
    func syntheticAzimuthWithoutLocationIsBearing() {
        let schema = DataRecord(
            definition: "http://sensorml.com/ont/swe/property/doaOutput",
            label: "DoA", name: "doa",
            fields: [
                DataField(name: "time", component: TimeStamp()),
                DataField(name: "azimuth", component: Quantity(
                    definition: "http://sensorml.com/ont/swe/property/AzimuthAngle",
                    label: "Azimuth", uom: "deg")),
                DataField(name: "slantRange", component: Quantity(
                    definition: "http://qudt.org/vocab/quantitykind/Distance",
                    label: "Slant Range", uom: "m")),
                DataField(name: "confidence", component: Quantity(
                    definition: "http://sensorml.com/ont/swe/property/ConfidenceValue",
                    label: "Confidence", uom: "1"))
            ])

        guard case .bearing(let paths) = DatastreamRoleInference.role(schema: schema) else {
            Issue.record("expected .bearing, got \(DatastreamRoleInference.role(schema: schema))")
            return
        }
        #expect(paths.angle.description == "/azimuth")
    }

    /// "range" is five characters, so a substring match finds it inside
    /// "AntennaArrangement". KrakenSDR's settings record has exactly that field
    /// two levels from a location vector, and the target rule must not fire.
    @Test("Adding the target rule changes no other fixture's role")
    func targetRuleChangesNothingElse() throws {
        #expect(try Self.role(.gps).label == "location")
        #expect(try Self.role(.aisVesselLocation).label == "location")
        #expect(try Self.role(.krakenDOA).label == "bearing")
        #expect(try Self.role(.krakenSettings).label == "status")
        #expect(try Self.role(.weather).label == "timeseries")
        #expect(try Self.role(.spectrumArray).label == "chart")
        #expect(try Self.role(.videoMJPEG).label == "video")

        // And the DOA paths themselves, since the Kraken line on the map is
        // drawn from them.
        guard case .bearing(let doa) = try Self.role(.krakenDOA) else {
            Issue.record("Kraken DOA is no longer a bearing")
            return
        }
        #expect(doa.angle.description == "/raw_lob")
        #expect(doa.quality?.description == "/confidence")
    }

    // MARK: Quaternion heading extraction

    @Test("Identity quaternion reads as 0°, a 90° yaw as 90°")
    func quaternionHeading() throws {
        let schema = GeoPosHelper.newQuatOrientationRecord(name: "quat_orientation_data",
                                                           localFrameURI: Self.frame)
        guard case .orientation(let paths) = DatastreamRoleInference.role(schema: schema) else {
            Issue.record("expected .orientation")
            return
        }

        func heading(x: Double, y: Double, z: Double, w: Double) throws -> Double {
            let observation = try SchemaWalker.parsedObservation(
                datastreamId: "quat", record: schema,
                scalars: [Date().timeIntervalSince1970, x, y, z, w])
            return try #require(paths.heading(from: observation))
        }

        #expect(try heading(x: 0, y: 0, z: 0, w: 1) == 0)

        // A rotation of θ about z is (0, 0, sin(θ/2), cos(θ/2)).
        let half = (Double.pi / 2) / 2
        let ninety = try heading(x: 0, y: 0, z: sin(half), w: cos(half))
        #expect(abs(ninety - 90) < 0.1)

        // And the wrap: −90° must come back as 270°, not as −90°.
        let minusNinety = try heading(x: 0, y: 0, z: sin(-half), w: cos(-half))
        #expect(abs(minusNinety - 270) < 0.1)
    }

    @Test("Euler heading is normalised into [0,360)")
    func eulerHeadingNormalises() throws {
        let schema = GeoPosHelper.newEulerOrientationRecord(name: "euler_orientation_data",
                                                            localFrameURI: Self.frame)
        guard case .orientation(let paths) = DatastreamRoleInference.role(schema: schema) else {
            Issue.record("expected .orientation")
            return
        }
        let observation = try SchemaWalker.parsedObservation(
            datastreamId: "euler", record: schema,
            scalars: [Date().timeIntervalSince1970, -45, 3, -2])
        #expect(try #require(paths.heading(from: observation)) == 315)
    }

    // MARK: Every fixture classifies

    @Test("Every captured observation schema gets a role and never crashes",
          arguments: FixtureLoader.Slug.allCases)
    func everyFixtureClassifies(slug: FixtureLoader.Slug) throws {
        guard FixtureLoader.data(slug, "schema-binary.json") != nil
                || FixtureLoader.data(slug, "schema-json.json") != nil else { return }
        let decoded = try Self.schema(slug)
        let role = DatastreamRoleInference.role(schema: decoded.recordSchema,
                                                encoding: decoded.recordEncoding,
                                                datastreamName: Self.datastreamName(slug))
        #expect(!role.label.isEmpty)
        #expect(!SystemGlyph.symbol(for: role).isEmpty)
    }
}
