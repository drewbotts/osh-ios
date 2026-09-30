import Testing
import Foundation
@testable import osh_ios

// MARK: - SensorMLPositionPatchTests
//
// The read-modify-write against real descriptions from the reference node
// (fixtures under survey-in/, captured 2026-09-15):
//
//   system-sml.json         Axis PTZ — has a GeoPose position (NED, 0/0/0 angles)
//   system-nopos-sml.json   DR-CAMERA — parameters, no position
//   system-frames-sml.json  this app's own iPhone registration — localReferenceFrames, no position
//   system.json             the Axis PTZ as GeoJSON, which is what the node
//                           serves when sml+json is not asked for by query

@Suite("SensorML position patch")
struct SensorMLPositionPatchTests {

    static let pose = SurveyedPose(latitude: 34.7250123, longitude: -86.5830456,
                                   heightAboveEllipsoid: 212.34,
                                   yaw: 217.5, pitch: 1.25, roll: -0.5)

    private func fixture(_ name: String) throws -> Data {
        try FixtureLoader.requiredData(.surveyIn, name)
    }

    // MARK: The element

    @Test("The position element is a GeoPose with type first")
    func geoPoseShape() {
        let element = SensorMLPositionPatch.geoPose(Self.pose)
        #expect(element.keys == ["type", "referenceFrame", "ltpReferenceFrame", "position", "angles"])
        #expect(element["type"]?.stringValue == "GeoPose")
        #expect(element["referenceFrame"]?.stringValue == "http://www.opengis.net/def/crs/EPSG/0/4979")
        #expect(element["ltpReferenceFrame"]?.stringValue == "http://www.opengis.net/def/cs/OGC/0/NED")
        #expect(element["position"]?.keys == ["lat", "lon", "h"])
        #expect(element["angles"]?.keys == ["yaw", "pitch", "roll"])
        #expect(element.serialized()
                == #"{"type":"GeoPose","referenceFrame":"http://www.opengis.net/def/crs/EPSG/0/4979","ltpReferenceFrame":"http://www.opengis.net/def/cs/OGC/0/NED","position":{"lat":34.7250123,"lon":-86.5830456,"h":212.34},"angles":{"yaw":217.5,"pitch":1.25,"roll":-0.5}}"#)
    }

    @Test("Yaw is normalised into [0, 360) on the way out")
    func yawNormalised() {
        var pose = Self.pose
        pose.yaw = -90
        #expect(SensorMLPositionPatch.geoPose(pose)["angles"]?["yaw"]?.doubleValue == 270)
    }

    // MARK: Replacing

    @Test("An existing position is replaced in place and everything else survives")
    func replacesExistingPosition() throws {
        let original = try fixture("system-sml.json")
        let patched = try SensorMLPositionPatch.apply(Self.pose, to: original)

        let before = try OrderedJSON.parse(original)
        let after = try OrderedJSON.parse(patched)

        // Same keys, same order — the position stayed where the node put it.
        #expect(after.keys == before.keys)
        #expect(before.keys.firstIndex(of: "position") == after.keys.firstIndex(of: "position"))

        // The one changed member.
        #expect(SensorMLPositionPatch.readPose(from: patched)?.matches(Self.pose) == true)

        // Every other member is byte-identical.
        for key in before.keys where key != "position" {
            #expect(after[key] == before[key], "member \(key) changed")
        }
        // The camera's whole DataChoice is still there, in order.
        #expect(after["parameters"]?.elements?.first?["items"]?.elements?.map { $0["name"]?.stringValue }
                == ["pan", "tilt", "zoom", "rpan", "rtilt", "rzoom", "preset", "ptzPos"])
    }

    @Test("The first key of the document and of the position is type")
    func typeFirst() throws {
        let patched = try SensorMLPositionPatch.apply(Self.pose, to: try fixture("system-sml.json"))
        let text = String(decoding: patched, as: UTF8.self)
        #expect(text.hasPrefix(#"{"type":"PhysicalSystem","#))
        #expect(text.contains(#""position":{"type":"GeoPose","#))
    }

    // MARK: Inserting

    @Test("A description with no position gets one after validTime, before parameters")
    func insertsBeforeParameters() throws {
        let patched = try SensorMLPositionPatch.apply(Self.pose, to: try fixture("system-nopos-sml.json"))
        let keys = try OrderedJSON.parse(patched).keys
        #expect(keys == ["type", "id", "uniqueId", "definition", "label", "description",
                         "validTime", "position", "parameters"])
        #expect(SensorMLPositionPatch.readPose(from: patched)?.matches(Self.pose) == true)
    }

    @Test("A description with local frames gets the position after them")
    func insertsAfterLocalFrames() throws {
        let patched = try SensorMLPositionPatch.apply(Self.pose, to: try fixture("system-frames-sml.json"))
        let keys = try OrderedJSON.parse(patched).keys
        #expect(keys == ["type", "id", "uniqueId", "label", "identifiers", "validTime",
                         "localReferenceFrames", "position"])
    }

    @Test("Applying the same pose twice is idempotent")
    func idempotent() throws {
        let once = try SensorMLPositionPatch.apply(Self.pose, to: try fixture("system-nopos-sml.json"))
        let twice = try SensorMLPositionPatch.apply(Self.pose, to: once)
        #expect(once == twice)
    }

    // MARK: Refusals

    @Test("A GeoJSON Feature is refused — the node serves one when f= is missing")
    func refusesFeature() throws {
        let feature = try fixture("system.json")
        #expect(throws: SensorMLPositionPatch.PatchError.notSensorML(type: "Feature")) {
            try SensorMLPositionPatch.apply(Self.pose, to: feature)
        }
    }

    @Test("A non-physical process is refused")
    func refusesSimpleProcess() throws {
        let doc = Data(#"{"type":"SimpleProcess","uniqueId":"urn:x:y","label":"proc"}"#.utf8)
        #expect(throws: SensorMLPositionPatch.PatchError.notPhysical(type: "SimpleProcess")) {
            try SensorMLPositionPatch.apply(Self.pose, to: doc)
        }
    }

    @Test("Non-JSON is refused with the parser's reason")
    func refusesGarbage() {
        #expect(throws: SensorMLPositionPatch.PatchError.self) {
            try SensorMLPositionPatch.apply(Self.pose, to: Data("<html>".utf8))
        }
    }

    // MARK: Reading back

    @Test("The node's own GeoPose reads back")
    func readsNodePose() throws {
        let pose = try #require(SensorMLPositionPatch.readPose(from: try fixture("system-sml.json")))
        #expect(abs(pose.latitude - 34.99950637619338) < 1e-12)
        #expect(abs(pose.longitude - -85.32749112287203) < 1e-12)
        #expect(pose.heightAboveEllipsoid == 0)
        #expect(pose.yaw == 0 && pose.pitch == 0 && pose.roll == 0)
    }

    @Test("A Point position or no position reads back as nil")
    func readsNilForPointOrNone() throws {
        #expect(SensorMLPositionPatch.readPose(from: try fixture("system-nopos-sml.json")) == nil)
        let point = Data(#"{"type":"PhysicalSystem","position":{"type":"Point","coordinates":[-86.6,34.7,200]}}"#.utf8)
        #expect(SensorMLPositionPatch.readPose(from: point) == nil)
    }

    @Test("matches() compares yaw around the circle")
    func matchesAroundCircle() {
        var other = Self.pose
        other.yaw = Self.pose.yaw - 360
        #expect(Self.pose.matches(other))
        other.yaw = Self.pose.yaw + 0.5
        #expect(!Self.pose.matches(other))
    }
}
