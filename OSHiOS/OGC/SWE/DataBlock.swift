import Foundation

// MARK: - Observation record
//
// Used to carry one observation from a SensorModule to the ObservationPublisher.
// Intentionally simple — typed union for the two cases we need:
//   .scalar  – small records (GPS, orientation): all values are Doubles/Floats
//   .video   – large binary records: timestamp + compressed Data

enum ObsPayload {
    /// GPS / orientation – flat ordered array of scalars matching the DataRecord field order.
    /// Index 0 is always the timestamp (Double seconds since Unix epoch).
    case scalar([Double])

    /// Video – timestamp (Double) + compressed frame bytes.
    case video(timestamp: Double, frame: Data)
}

struct Observation {
    let datastreamName: String  // matches SensorModule.outputName, used to route to correct datastream
    let payload: ObsPayload
}
