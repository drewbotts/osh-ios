import Foundation

// MARK: - SurveyOutputSchemas
//
// The two outputs a survey creates on a system that has none: the same shape
// osh-core's AbstractSensorModule gives a driver configured with a Position,
// captured from the Axis PTZ on the reference node (fixtures
// survey-in/sensor-location-schema.json and sensor-orientation-schema.json).
//
// Same names, definitions, labels, frames and axis ids, so that everything
// downstream — this app's role inference, the node's own viewer, any other
// client that already understands a driver's `sensorLocation` — treats a
// surveyed system exactly like a configured one. The one thing not copied is
// the driver's `localFrame` (`#REF_FRAME_AXIS_CAM_…`), which names a frame
// in that driver's SensorML; a survey has no such frame to point at.

enum SurveyOutputSchemas {

    static let locationOutputName = "sensorLocation"
    static let orientationOutputName = "sensorOrientation"

    static let samplingTimeDefinition = "http://www.opengis.net/def/property/OGC/0/SamplingTime"
    static let nedFrame = "http://www.opengis.net/def/cs/OGC/0/NED"

    /// `sensorLocation`: time + location{lat, lon, alt} in EPSG 4979.
    static func location() -> DataRecord {
        let lat = Quantity(definition: GeoPosHelper.DEF_LATITUDE_GEODETIC,
                           label: "Geodetic Latitude", uom: "deg", axisId: "Lat")
        let lon = Quantity(definition: GeoPosHelper.DEF_LONGITUDE,
                           label: "Longitude", uom: "deg", axisId: "Lon")
        let alt = Quantity(definition: GeoPosHelper.DEF_ALTITUDE_ELLIPSOID,
                           label: "Ellipsoidal Height",
                           description: "Altitude above WGS84 ellipsoid",
                           uom: "m", axisId: "h")
        let vector = SWEVector(definition: SurveyWriteStrategy.sensorLocationDefinition,
                               refFrame: SWEConstants.refFrame_WGS84_HAE,
                               coordinates: [DataField(name: "lat", component: lat),
                                             DataField(name: "lon", component: lon),
                                             DataField(name: "alt", component: alt)])
        return DataRecord(label: "Sensor Location",
                          name: locationOutputName,
                          fields: [DataField(name: "time", component: samplingTime()),
                                   DataField(name: "location", component: vector)])
    }

    /// `sensorOrientation`: time + orientation{heading, pitch, roll} in NED —
    /// the mount at pan/tilt zero, as the Axis driver describes it.
    static func orientation() -> DataRecord {
        let heading = Quantity(definition: GeoPosHelper.DEF_HEADING_TRUE,
                               label: "Heading Angle",
                               description: "Heading angle from true north, measured clockwise",
                               uom: "deg", axisId: "Z")
        let pitch = Quantity(definition: GeoPosHelper.DEF_PITCH_ANGLE,
                             label: "Pitch Angle",
                             description: "Rotation around the lateral axis, up/down from the local horizontal plane (positive when pointing up)",
                             uom: "deg", axisId: "Y")
        let roll = Quantity(definition: GeoPosHelper.DEF_ROLL_ANGLE,
                            label: "Roll Angle",
                            description: "Rotation around the longitudinal axis",
                            uom: "deg", axisId: "X")
        let vector = SWEVector(definition: SurveyWriteStrategy.sensorOrientationDefinition,
                               description: "Euler angles with order of rotation heading/pitch/roll in rotating frame",
                               refFrame: nedFrame,
                               coordinates: [DataField(name: "heading", component: heading),
                                             DataField(name: "pitch", component: pitch),
                                             DataField(name: "roll", component: roll)])
        return DataRecord(label: "Platform Orientation",
                          name: orientationOutputName,
                          fields: [DataField(name: "time", component: samplingTime()),
                                   DataField(name: "orientation", component: vector)],
                          description: "Static mount orientation of the platform at its installed position, in the NED frame; for a PTZ camera, with pan and tilt at zero. Surveyed in from a phone.")
    }

    private static func samplingTime() -> TimeStamp {
        TimeStamp(definition: samplingTimeDefinition, label: "Sampling Time")
    }

    /// The encoding `registerDatastream` wants for a scalar stream. Only its
    /// lack of a block member matters: it is what marks the stream swe+json.
    static func scalarEncoding(_ refs: [String]) -> BinaryEncoding {
        BinaryEncoding(fields: refs.map { BinaryFieldEncoding(ref: $0, type: .scalar(.double)) })
    }
}
