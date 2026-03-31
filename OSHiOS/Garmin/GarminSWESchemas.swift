import Foundation

// MARK: - GarminSWESchemas
//
// SWE Common DataRecord schemas for all Garmin sensor outputs.
//
// DataBlock layouts (all index 0 = Double Unix epoch timestamp):
//   heartRate:      [time, bpm (float)]
//   stress:         [time, stressScore (float, 0–100)]
//   respiration:    [time, breathsPerMinute (float)]
//   accelerometer:  [time, ax (float), ay (float), az (float)]
//   fitSync:        [time, fileCount (int), deviceName (string)] — text record, no binary encoding

enum GarminSWESchemas {

    // MARK: - Definition URIs

    private static let DEF_HEART_RATE         = SWEConstants.propertyURI("HeartRate")
    private static let DEF_STRESS_SCORE       = SWEConstants.propertyURI("StressScore")
    private static let DEF_RESPIRATION_RATE   = SWEConstants.propertyURI("RespirationRate")
    private static let DEF_ACCELERATION       = SWEConstants.propertyURI("Acceleration")
    private static let DEF_GARMIN_HEART_RATE  = SWEConstants.propertyURI("GarminHeartRate")
    private static let DEF_GARMIN_STRESS      = SWEConstants.propertyURI("GarminStress")
    private static let DEF_GARMIN_RESPIRATION = SWEConstants.propertyURI("GarminRespiration")
    private static let DEF_GARMIN_ACCEL       = SWEConstants.propertyURI("GarminAccelerometer")

    // MARK: - Heart Rate
    //
    // Fields: time (Double), bpm (Float)

    static func heartRateRecord(name: String) -> DataRecord {
        DataRecord(
            definition: DEF_GARMIN_HEART_RATE,
            label: "Heart Rate",
            name: name,
            fields: [
                DataField(name: "time", component: TimeStamp()),
                DataField(name: "bpm", component: Quantity(
                    definition: DEF_HEART_RATE,
                    label: "Heart Rate",
                    uom: "beat/min",
                    dataType: .float
                ))
            ]
        )
    }

    static func heartRateEncoding() -> BinaryEncoding {
        BinaryEncoding(fields: [
            BinaryFieldEncoding(ref: "/time", type: .scalar(.double)),
            BinaryFieldEncoding(ref: "/bpm",  type: .scalar(.float))
        ])
    }

    // MARK: - Stress Score
    //
    // Fields: time (Double), stressScore (Float, 0–100)

    static func stressRecord(name: String) -> DataRecord {
        DataRecord(
            definition: DEF_GARMIN_STRESS,
            label: "Stress Score",
            name: name,
            fields: [
                DataField(name: "time", component: TimeStamp()),
                DataField(name: "stressScore", component: Quantity(
                    definition: DEF_STRESS_SCORE,
                    label: "Stress Score",
                    uom: "1",
                    dataType: .float
                ))
            ]
        )
    }

    static func stressEncoding() -> BinaryEncoding {
        BinaryEncoding(fields: [
            BinaryFieldEncoding(ref: "/time",        type: .scalar(.double)),
            BinaryFieldEncoding(ref: "/stressScore", type: .scalar(.float))
        ])
    }

    // MARK: - Respiration Rate
    //
    // Fields: time (Double), breathsPerMinute (Float)

    static func respirationRecord(name: String) -> DataRecord {
        DataRecord(
            definition: DEF_GARMIN_RESPIRATION,
            label: "Respiration Rate",
            name: name,
            fields: [
                DataField(name: "time", component: TimeStamp()),
                DataField(name: "breathsPerMinute", component: Quantity(
                    definition: DEF_RESPIRATION_RATE,
                    label: "Respiration Rate",
                    uom: "breath/min",
                    dataType: .float
                ))
            ]
        )
    }

    static func respirationEncoding() -> BinaryEncoding {
        BinaryEncoding(fields: [
            BinaryFieldEncoding(ref: "/time",               type: .scalar(.double)),
            BinaryFieldEncoding(ref: "/breathsPerMinute",   type: .scalar(.float))
        ])
    }

    // MARK: - Accelerometer
    //
    // Fields: time (Double), ax (Float), ay (Float), az (Float) — device frame, m/s²

    static func accelerometerRecord(name: String, localFrameURI: String) -> DataRecord {
        let accelVec = SWEVector(
            definition: DEF_ACCELERATION,
            label: "Acceleration Vector",
            refFrame: localFrameURI,
            localFrame: nil,
            coordinates: [
                DataField(name: "ax", component: Quantity(
                    definition: SWEConstants.defCoef, label: "X Acceleration",
                    uom: "m/s2", dataType: .float, axisId: "X")),
                DataField(name: "ay", component: Quantity(
                    definition: SWEConstants.defCoef, label: "Y Acceleration",
                    uom: "m/s2", dataType: .float, axisId: "Y")),
                DataField(name: "az", component: Quantity(
                    definition: SWEConstants.defCoef, label: "Z Acceleration",
                    uom: "m/s2", dataType: .float, axisId: "Z"))
            ]
        )
        return DataRecord(
            definition: DEF_GARMIN_ACCEL,
            label: "Accelerometer",
            name: name,
            fields: [
                DataField(name: "time",         component: TimeStamp()),
                DataField(name: "acceleration", component: accelVec)
            ]
        )
    }

    static func accelerometerEncoding() -> BinaryEncoding {
        BinaryEncoding(fields: [
            BinaryFieldEncoding(ref: "/time",                type: .scalar(.double)),
            BinaryFieldEncoding(ref: "/acceleration/ax",     type: .scalar(.float)),
            BinaryFieldEncoding(ref: "/acceleration/ay",     type: .scalar(.float)),
            BinaryFieldEncoding(ref: "/acceleration/az",     type: .scalar(.float))
        ])
    }
}
