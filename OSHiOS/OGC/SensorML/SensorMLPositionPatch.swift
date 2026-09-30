import Foundation

// MARK: - SensorMLPositionPatch
//
// Writing a surveyed position into a system's SensorML description.
//
// A static emplacement is a property of the system, not an observation of it,
// so it goes in the description — `GET /systems/{id}` as SensorML, edit,
// `PUT /systems/{id}` — rather than into a datastream. This is the edit.
//
// The structure is the node's own. On the reference node (osh-core 2.0.2) a
// camera whose driver was configured with a location and an orientation is
// described as
//
//     "position": {
//       "type": "GeoPose",
//       "ltpReferenceFrame": "http://www.opengis.net/def/cs/OGC/0/NED",
//       "position": { "lat": 34.99950637619338, "lon": -85.32749112287203, "h": 0.0 },
//       "angles":   { "yaw": 0.0, "pitch": 0.0, "roll": 0.0 }
//     }
//
// and the node's reader (SMLJsonBindings.readPosition → GeoPoseJsonBindings)
// accepts exactly three shapes for that element, dispatched on a `type` that
// must be the first key: "GeoPose", "RelativePose" and a GeoJSON "Point". The
// pose reader takes `referenceFrame`, `ltpReferenceFrame`, `localFrame`,
// `position` (lat/lon/h or x/y/z) and either `angles` (yaw/pitch/roll) or
// `quaternion` (x/y/z/w), in any order, skipping anything else.
//
// Frames, because they are the whole point:
//
//   • `referenceFrame` is EPSG 4979 — WGS 84 with *ellipsoidal* height, so `h`
//     is HAE, which is what CLLocation.ellipsoidalAltitude reports. (The node
//     defaults an unstated frame to OGC CRS84h, which means the same thing; the
//     tag is written so the intent is on the wire.)
//   • `ltpReferenceFrame` is NED, mirroring what the node writes for its own
//     drivers. In a north-east-down tangent plane `yaw` is a compass heading:
//     degrees clockwise from true north, 0 = north, 90 = east. In the GeoPose
//     default (ENU) it would not be, and a viewer doing slew-to-cue against
//     this pose would inherit a 90° error.
//
// Everything else in the description is preserved byte-for-byte in content and
// in order — see OrderedJSON for why order matters here.

/// A surveyed emplacement, ready to write.
struct SurveyedPose: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    /// Metres above the WGS 84 ellipsoid — *not* mean sea level.
    var heightAboveEllipsoid: Double
    /// Degrees clockwise from true north, [0, 360).
    var yaw: Double
    /// Degrees, positive nose-up (NED).
    var pitch: Double
    /// Degrees, positive right-side-down (NED).
    var roll: Double

    init(latitude: Double, longitude: Double, heightAboveEllipsoid: Double,
         yaw: Double, pitch: Double = 0, roll: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.heightAboveEllipsoid = heightAboveEllipsoid
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }

    /// True when every figure agrees with `other` to within survey tolerance:
    /// a centimetre on the ground and a hundredth of a degree in attitude,
    /// with yaw compared around the circle.
    func matches(_ other: SurveyedPose) -> Bool {
        abs(latitude - other.latitude) < 1e-7
            && abs(SurveyMath.signedDifference(longitude, minus: other.longitude)) < 1e-7
            && abs(heightAboveEllipsoid - other.heightAboveEllipsoid) < 0.01
            && abs(SurveyMath.signedDifference(yaw, minus: other.yaw)) < 0.01
            && abs(pitch - other.pitch) < 0.01
            && abs(roll - other.roll) < 0.01
    }
}

enum SensorMLPositionPatch {

    // MARK: Vocabulary

    static let positionKey = "position"
    static let geoPoseType = "GeoPose"
    static let pointType = "Point"
    static let referenceFrameEPSG4979 = "http://www.opengis.net/def/crs/EPSG/0/4979"
    static let ltpReferenceFrameNED = "http://www.opengis.net/def/cs/OGC/0/NED"

    /// The SensorML types a position may be written to. A SimpleProcess or an
    /// AggregateProcess has no physical location by definition, and the node's
    /// reader would not look for one.
    static let physicalTypes: Set<String> = ["PhysicalSystem", "PhysicalComponent"]

    /// Where a new `position` goes when the description has none: directly
    /// after the last of these that is present. This is the order the node's
    /// own writer emits — the described-object properties, then the physical
    /// process ones with `position` last among them — so an inserted element
    /// lands where the node would have put it, ahead of inputs, outputs,
    /// parameters and components.
    static let positionAnchors: [String] = [
        "type", "id", "uniqueId", "definition", "label", "description", "lang",
        "keywords", "identifiers", "classifiers", "validTime",
        "securityConstraints", "legalConstraints", "characteristics",
        "capabilities", "contacts", "documents",
        "attachedTo", "localReferenceFrames"
    ]

    // MARK: Errors

    enum PatchError: Error, LocalizedError, Equatable {
        /// The bytes were not JSON at all.
        case notJSON(String)
        /// JSON, but not a SensorML process — a GeoJSON Feature is the usual
        /// culprit, which is what the node serves when the format was not
        /// asked for explicitly.
        case notSensorML(type: String?)
        /// A SensorML process that cannot carry a position.
        case notPhysical(type: String)

        var errorDescription: String? {
            switch self {
            case .notJSON(let detail):
                return "System description is not JSON: \(detail)"
            case .notSensorML(let type):
                return "System description is not SensorML (type \(type ?? "missing")) — was the sml+json format requested?"
            case .notPhysical(let type):
                return "A \(type) has no physical position to write"
            }
        }
    }

    // MARK: Building

    /// The `position` element for a pose, keys in the node's own order.
    static func geoPose(_ pose: SurveyedPose) -> OrderedJSON {
        .object([
            .init("type", .string(geoPoseType)),
            .init("referenceFrame", .string(referenceFrameEPSG4979)),
            .init("ltpReferenceFrame", .string(ltpReferenceFrameNED)),
            .init("position", .object([
                .init("lat", .number(pose.latitude)),
                .init("lon", .number(pose.longitude)),
                .init("h", .number(pose.heightAboveEllipsoid))
            ])),
            .init("angles", .object([
                .init("yaw", .number(SurveyMath.normalizedDegrees(pose.yaw))),
                .init("pitch", .number(pose.pitch)),
                .init("roll", .number(pose.roll))
            ]))
        ])
    }

    // MARK: Applying

    /// The description with `pose` as its position, everything else untouched.
    static func apply(_ pose: SurveyedPose, to document: Data) throws -> Data {
        let root: OrderedJSON
        do {
            root = try OrderedJSON.parse(document)
        } catch {
            throw PatchError.notJSON(error.localizedDescription)
        }
        return try apply(pose, to: root).serializedData()
    }

    static func apply(_ pose: SurveyedPose, to root: OrderedJSON) throws -> OrderedJSON {
        guard root.members != nil else { throw PatchError.notSensorML(type: nil) }
        guard let type = root["type"]?.stringValue else { throw PatchError.notSensorML(type: nil) }
        guard type != "Feature", type != "FeatureCollection" else {
            throw PatchError.notSensorML(type: type)
        }
        guard physicalTypes.contains(type) else { throw PatchError.notPhysical(type: type) }

        return root.setting(positionKey, to: geoPose(pose), insertingAfter: positionAnchors)
    }

    // MARK: Reading back

    /// The pose a description states, when it states one as a GeoPose.
    ///
    /// nil for no position, for a position written as a bare Point (which has
    /// no orientation to compare) and for a RelativePose. `angles` absent
    /// reads as zero, which is what the node's writer emits for a pose whose
    /// orientation was never set.
    static func readPose(from document: Data) -> SurveyedPose? {
        guard let root = try? OrderedJSON.parse(document) else { return nil }
        return readPose(from: root)
    }

    static func readPose(from root: OrderedJSON) -> SurveyedPose? {
        guard let position = root[positionKey],
              position["type"]?.stringValue == geoPoseType,
              let point = position["position"],
              let latitude = point["lat"]?.doubleValue,
              let longitude = point["lon"]?.doubleValue else { return nil }

        let angles = position["angles"]
        return SurveyedPose(latitude: latitude,
                            longitude: longitude,
                            heightAboveEllipsoid: point["h"]?.doubleValue ?? 0,
                            yaw: angles?["yaw"]?.doubleValue ?? 0,
                            pitch: angles?["pitch"]?.doubleValue ?? 0,
                            roll: angles?["roll"]?.doubleValue ?? 0)
    }

    /// The name a description gives itself, for messages.
    static func label(of document: Data) -> String? {
        guard let root = try? OrderedJSON.parse(document) else { return nil }
        return root["label"]?.stringValue ?? root["name"]?.stringValue
    }
}
