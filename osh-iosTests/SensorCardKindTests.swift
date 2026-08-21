import Foundation
import Testing
@testable import osh_ios

// MARK: - SensorCardKind
//
// The card's body is chosen from the schema alone — no `is GPSOutput` anywhere
// — because the same component has to render a datastream read back from a
// node. These tests are the guard rail on that: they only ever hand the
// decision a DataRecord.

struct SensorCardKindTests {

    private static let frame = "urn:osh:ios:test#LOCAL_FRAME"

    @Test func gpsRecordRendersAsALocation() {
        let schema = GeoPosHelper.newLocationRecord(name: "gps_data", localFrameURI: Self.frame)
        guard case .location(let paths) = SensorCardKind.from(schema: schema) else {
            Issue.record("Expected .location, got \(SensorCardKind.from(schema: schema))")
            return
        }
        #expect(paths.latitude.description == "/location/lat")
        #expect(paths.longitude.description == "/location/lon")
        #expect(paths.altitude?.description == "/location/alt")
    }

    @Test func videoRecordRendersAsVideo() {
        let (schema, _) = VideoCamHelper.newVideoOutputCODEC(name: "camera0_H264",
                                                             width: 1280, height: 720,
                                                             codec: "H264")
        #expect(SensorCardKind.from(schema: schema) == .video)
    }

    @Test func orientationRecordsFallBackToFields() {
        let euler = GeoPosHelper.newEulerOrientationRecord(name: "euler_orientation_data",
                                                            localFrameURI: Self.frame)
        let quat = GeoPosHelper.newQuatOrientationRecord(name: "quat_orientation_data",
                                                         localFrameURI: Self.frame)
        #expect(SensorCardKind.from(schema: euler) == .fields)
        #expect(SensorCardKind.from(schema: quat) == .fields)
    }

    @Test func flatScalarRecordRendersAsFields() {
        let schema = DataRecord(
            definition: "http://sensorml.com/ont/swe/property/AtmosphericPressure",
            label: "Barometer",
            name: "barometer",
            fields: [
                DataField(name: "time", component: TimeStamp()),
                DataField(name: "pressure", component: Quantity(label: "Pressure", uom: "hPa"))
            ])
        #expect(SensorCardKind.from(schema: schema) == .fields)
    }

    /// A remote datastream may name its coordinates anything; the definitions
    /// are the interoperable part, so they decide.
    @Test func coordinatesAreFoundByDefinitionNotByName() {
        let vector = SWEVector(
            definition: GeoPosHelper.DEF_LOCATION_VECTOR,
            label: "Position",
            coordinates: [
                DataField(name: "y", component: Quantity(
                    definition: GeoPosHelper.DEF_LATITUDE_GEODETIC, uom: "deg")),
                DataField(name: "x", component: Quantity(
                    definition: GeoPosHelper.DEF_LONGITUDE, uom: "deg")),
                DataField(name: "z", component: Quantity(
                    definition: GeoPosHelper.DEF_ALTITUDE_ELLIPSOID, uom: "m"))
            ])
        let schema = DataRecord(definition: nil, label: "Remote", name: "remote",
                                fields: [
                                    DataField(name: "time", component: TimeStamp()),
                                    DataField(name: "pos", component: vector)
                                ])

        guard case .location(let paths) = SensorCardKind.from(schema: schema) else {
            Issue.record("Expected .location")
            return
        }
        #expect(paths.latitude.description == "/pos/y")
        #expect(paths.longitude.description == "/pos/x")
        #expect(paths.altitude?.description == "/pos/z")
    }

    /// Definitions are optional in the wild; names are the fallback.
    @Test func coordinatesAreFoundByNameWhenDefinitionsAreAbsent() {
        let vector = SWEVector(
            definition: "http://example.org/def/LocationVector",
            label: "Position",
            coordinates: [
                DataField(name: "lat", component: Quantity(uom: "deg")),
                DataField(name: "lon", component: Quantity(uom: "deg"))
            ])
        let schema = DataRecord(definition: nil, label: nil, name: "remote",
                                fields: [DataField(name: "loc", component: vector)])

        guard case .location(let paths) = SensorCardKind.from(schema: schema) else {
            Issue.record("Expected .location")
            return
        }
        #expect(paths.latitude.description == "/loc/lat")
        #expect(paths.longitude.description == "/loc/lon")
        #expect(paths.altitude == nil)
    }

    /// A Vector that is not a location — an orientation, say — must not be
    /// mistaken for one just because it has three coordinates.
    @Test func nonLocationVectorIsNotAFix() {
        let vector = SWEVector(
            definition: GeoPosHelper.DEF_ORIENTATION_EULER,
            coordinates: [
                DataField(name: "lat", component: Quantity(uom: "deg")),
                DataField(name: "lon", component: Quantity(uom: "deg"))
            ])
        let schema = DataRecord(definition: nil, label: nil, name: "orient",
                                fields: [DataField(name: "orient", component: vector)])
        #expect(SensorCardKind.from(schema: schema) == .fields)
    }
}
