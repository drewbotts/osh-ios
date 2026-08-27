import Testing
import Foundation
@testable import osh_ios

// MARK: - LocationPathsTests
//
// Pass 3b made the search recursive. These are the guard rails on both halves
// of that: the new behaviour — a position buried in a settings record resolves
// — and the old one, because the Live tab's location card and the map both read
// the same answer and neither may change.

@Suite("Location and heading paths")
struct LocationPathsTests {

    private static let frame = "urn:osh:ios:test#LOCAL_FRAME"

    // MARK: Unchanged behaviour

    @Test("A top-level location resolves exactly as it did")
    func topLevelUnchanged() throws {
        let schema = GeoPosHelper.newLocationRecord(name: "gps_data", localFrameURI: Self.frame)
        let paths = try #require(LocationPaths.resolve(in: schema))
        #expect(paths.latitude.description == "/location/lat")
        #expect(paths.longitude.description == "/location/lon")
        #expect(paths.altitude?.description == "/location/alt")
    }

    @Test("A record with no location vector still resolves to nothing")
    func noLocation() {
        let schema = DataRecord(definition: nil, label: nil, name: "barometer",
                                fields: [
                                    DataField(name: "time", component: TimeStamp()),
                                    DataField(name: "pressure",
                                              component: Quantity(label: "Pressure", uom: "hPa"))
                                ])
        #expect(LocationPaths.resolve(in: schema) == nil)
    }

    @Test("An orientation vector is not a fix, however its coordinates are named")
    func orientationIsNotALocation() {
        let schema = GeoPosHelper.newQuatOrientationRecord(name: "quat", localFrameURI: Self.frame)
        #expect(LocationPaths.resolve(in: schema) == nil)
    }

    // MARK: Recursion

    @Test("A position nested inside a settings record resolves, with its path")
    func nestedLocationResolves() throws {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.krakenSettings, "schema-json.json")).recordSchema

        let resolved = try #require(LocationPaths.resolveDetailed(in: schema))
        #expect(resolved.paths.latitude.description == "/stationConfig/location/lat")
        #expect(resolved.paths.longitude.description == "/stationConfig/location/lon")
        #expect(resolved.paths.altitude == nil)
        #expect(resolved.containerPath.description == "/stationConfig")
    }

    /// Breadth before depth. A schema with a fix at the top and another buried
    /// must resolve to the top one — that is the position the record is about.
    @Test("A top-level fix wins over a nested one")
    func topLevelWinsOverNested() throws {
        let vector = SWEVector(definition: GeoPosHelper.DEF_LOCATION_VECTOR,
                               coordinates: [
                                   DataField(name: "lat", component: Quantity(uom: "deg")),
                                   DataField(name: "lon", component: Quantity(uom: "deg"))
                               ])
        let nested = DataRecord(definition: nil, label: nil, name: "config",
                                fields: [DataField(name: "location", component: vector)])
        let schema = DataRecord(definition: nil, label: nil, name: "mixed",
                                fields: [
                                    DataField(name: "config", component: nested),
                                    DataField(name: "fix", component: vector)
                                ])
        let resolved = try #require(LocationPaths.resolveDetailed(in: schema))
        #expect(resolved.paths.latitude.description == "/fix/lat")
    }

    // MARK: Heading

    @Test("Heading comes from the location's own record before the top level")
    func headingPrefersSiblings() throws {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.krakenSettings, "schema-json.json")).recordSchema
        let resolved = try #require(LocationPaths.resolveDetailed(in: schema))
        #expect(HeadingPath.resolve(in: schema, near: resolved)?.description
                == "/stationConfig/heading")
    }

    /// A true heading is where the hull points; course over ground is where the
    /// ship is going. AIS carries both, and a rotated marker wants the first.
    @Test("True heading beats course over ground")
    func trueHeadingBeatsCourse() throws {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.aisVesselLocation, "schema-json.json")).recordSchema
        let resolved = try #require(LocationPaths.resolveDetailed(in: schema))
        #expect(HeadingPath.resolve(in: schema, near: resolved)?.description == "/heading")
    }

    @Test("Course over ground is used when nothing better is offered")
    func courseIsTheFallback() throws {
        let vector = SWEVector(definition: GeoPosHelper.DEF_LOCATION_VECTOR,
                               coordinates: [
                                   DataField(name: "lat", component: Quantity(uom: "deg")),
                                   DataField(name: "lon", component: Quantity(uom: "deg"))
                               ])
        let schema = DataRecord(definition: nil, label: nil, name: "drifter",
                                fields: [
                                    DataField(name: "location", component: vector),
                                    DataField(name: "cog", component: Quantity(
                                        definition: "http://example.org/def/CourseOverGround",
                                        uom: "deg"))
                                ])
        let resolved = try #require(LocationPaths.resolveDetailed(in: schema))
        #expect(HeadingPath.resolve(in: schema, near: resolved)?.description == "/cog")
    }

    @Test("A record with no angle at all has no heading")
    func noHeading() throws {
        let schema = GeoPosHelper.newLocationRecord(name: "gps_data", localFrameURI: Self.frame)
        let resolved = try #require(LocationPaths.resolveDetailed(in: schema))
        #expect(HeadingPath.resolve(in: schema, near: resolved) == nil)
    }
}
