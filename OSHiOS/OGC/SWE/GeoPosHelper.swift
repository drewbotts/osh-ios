import Foundation

// MARK: - GeoPosHelper
//
// Builds SWE Common data records for geolocation and orientation,
// matching the Java GeoPosHelper and AndroidLocationOutput / AndroidOrientationOutput schemas.
//
// Definition URIs are taken directly from the Android GeoPosHelper constants.

enum GeoPosHelper {

    // --- definition URIs (matching Android GeoPosHelper) ---
    static let DEF_LOCATION              = SWEConstants.propertyURI("Location")
    static let DEF_LOCATION_VECTOR       = SWEConstants.propertyURI("LocationVector")
    static let DEF_LATITUDE_GEODETIC     = SWEConstants.propertyURI("GeodeticLatitude")
    static let DEF_LONGITUDE             = SWEConstants.propertyURI("Longitude")
    static let DEF_ALTITUDE_ELLIPSOID    = SWEConstants.propertyURI("HeightAboveEllipsoid")
    static let DEF_HEADING_TRUE          = SWEConstants.propertyURI("TrueHeading")
    static let DEF_PITCH_ANGLE           = SWEConstants.propertyURI("PitchAngle")
    static let DEF_ROLL_ANGLE            = SWEConstants.propertyURI("RollAngle")
    // Matches Android VectorHelper constants (EulerAngles / RotationQuaternion)
    static let DEF_ORIENTATION_EULER     = SWEConstants.propertyURI("EulerAngles")
    static let DEF_ORIENTATION_QUAT      = SWEConstants.propertyURI("RotationQuaternion")

    // MARK: GPS location record
    //
    // Mirrors AndroidLocationOutput:
    //   posDataStruct.setDefinition("http://sensorml.com/ont/swe/property/Location")
    //   addComponent("time", newTimeStampIsoUTC())
    //   addComponent("location", newLocationVectorLLA(null))
    //     => sub-fields: lat (deg), lon (deg), alt (m)
    //
    // DataBlock layout (by index):
    //   0: time (Double, seconds since Unix epoch)
    //   1: lat  (Double, degrees)
    //   2: lon  (Double, degrees)
    //   3: alt  (Double, metres)
    static func newLocationRecord(name: String, localFrameURI: String) -> DataRecord {
        let lat = Quantity(
            definition: DEF_LATITUDE_GEODETIC,
            label: "Geodetic Latitude",
            uom: "deg",
            dataType: .double,
            axisId: "Lat",
            refFrame: nil
        )
        let lon = Quantity(
            definition: DEF_LONGITUDE,
            label: "Longitude",
            uom: "deg",
            dataType: .double,
            axisId: "Lon",
            refFrame: nil
        )
        let alt = Quantity(
            definition: DEF_ALTITUDE_ELLIPSOID,
            label: "Ellipsoidal Height",
            description: "Altitude above WGS84 ellipsoid",
            uom: "m",
            dataType: .double,
            axisId: "h",
            refFrame: nil
        )
        let locationVec = SWEVector(
            definition: DEF_LOCATION_VECTOR,
            label: "Location",
            refFrame: SWEConstants.refFrame_WGS84_HAE,
            localFrame: localFrameURI,
            coordinates: [
                DataField(name: "lat", component: lat),
                DataField(name: "lon", component: lon),
                DataField(name: "alt", component: alt)
            ]
        )
        return DataRecord(
            definition: DEF_LOCATION,
            label: "Location",
            name: name,
            fields: [
                DataField(name: "time",     component: TimeStamp()),
                DataField(name: "location", component: locationVec)
            ]
        )
    }

    // MARK: Quaternion orientation record
    //
    // Mirrors AndroidOrientationQuatOutput:
    //   dataStruct.setDefinition("http://sensorml.com/ont/swe/property/OrientationQuaternion")
    //   addComponent("time", ...)
    //   addComponent("orient", newQuatOrientationENU(null))
    //     => sub-fields: qx, qy, qz, q0 (all float, unitless "1")
    //
    // DataBlock layout (by index):
    //   0: time (Double)
    //   1: qx   (Float)
    //   2: qy   (Float)
    //   3: qz   (Float)
    //   4: q0   (Float, scalar)
    static func newQuatOrientationRecord(name: String, localFrameURI: String) -> DataRecord {
        let quatVec = SWEVector(
            definition: DEF_ORIENTATION_QUAT,
            label: "Orientation Quaternion",
            description: "Orientation quaternion, usually normalized",
            refFrame: SWEConstants.refFrame_ENU,
            localFrame: localFrameURI,
            coordinates: [
                DataField(name: "qx", component: Quantity(
                    definition: SWEConstants.defCoef, label: "X Component",
                    uom: "1", dataType: .float, axisId: "X")),
                DataField(name: "qy", component: Quantity(
                    definition: SWEConstants.defCoef, label: "Y Component",
                    uom: "1", dataType: .float, axisId: "Y")),
                DataField(name: "qz", component: Quantity(
                    definition: SWEConstants.defCoef, label: "Z Component",
                    uom: "1", dataType: .float, axisId: "Z")),
                DataField(name: "q0", component: Quantity(
                    definition: SWEConstants.defCoef, label: "Scalar Component",
                    uom: "1", dataType: .float, axisId: nil))
            ]
        )
        return DataRecord(
            definition: DEF_ORIENTATION_QUAT,
            label: "Orientation Quaternion",
            name: name,
            fields: [
                DataField(name: "time",   component: TimeStamp()),
                DataField(name: "orient", component: quatVec)
            ]
        )
    }

    // MARK: Euler orientation record
    //
    // Mirrors AndroidOrientationEulerOutput (ENU frame, degrees):
    //   dataStruct.setDefinition("http://sensorml.com/ont/swe/property/OrientationEuler")
    //   addComponent("time", ...)
    //   addComponent("orient", newEulerOrientationENU(null, "deg"))
    //     => heading (MagneticHeading, -180..180 deg)
    //        pitch   (PitchAngle,       -90..90  deg)
    //        roll    (RollAngle,        -180..180 deg)
    //
    // DataBlock layout (by index):
    //   0: time    (Double)
    //   1: heading (Float, degrees)
    //   2: pitch   (Float, degrees)
    //   3: roll    (Float, degrees)
    static func newEulerOrientationRecord(name: String, localFrameURI: String) -> DataRecord {
        let heading = Quantity(
            definition: DEF_HEADING_TRUE,
            label: "Heading Angle",
            description: "Heading angle from east direction, measured counter clockwise",
            uom: "deg",
            dataType: .float,
            axisId: "Z"
        )
        let pitch = Quantity(
            definition: DEF_PITCH_ANGLE,
            label: "Pitch Angle",
            description: "Rotation around the lateral axis, up/down from the local horizontal plane (positive when pointing up)",
            uom: "deg",
            dataType: .float,
            axisId: "X"
        )
        let roll = Quantity(
            definition: DEF_ROLL_ANGLE,
            label: "Roll Angle",
            description: "Rotation around the longitudinal axis",
            uom: "deg",
            dataType: .float,
            axisId: "Y"
        )
        let eulerVec = SWEVector(
            definition: DEF_ORIENTATION_EULER,
            label: "Euler Orientation ENU",
            description: "Euler angles with order of rotation heading/pitch/roll in rotating frame",
            refFrame: SWEConstants.refFrame_ENU,
            localFrame: localFrameURI,
            coordinates: [
                DataField(name: "heading", component: heading),
                DataField(name: "pitch",   component: pitch),
                DataField(name: "roll",    component: roll)
            ]
        )
        return DataRecord(
            definition: DEF_ORIENTATION_EULER,
            label: "Euler Orientation",
            name: name,
            fields: [
                DataField(name: "time",   component: TimeStamp()),
                DataField(name: "orient", component: eulerVec)
            ]
        )
    }
}
