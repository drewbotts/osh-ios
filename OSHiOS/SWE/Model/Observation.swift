import Foundation

// MARK: - Observation
//
// Carries one observation from a SensorModule to the ObservationPublisher.
// Intentionally simple — a typed union for the two cases we need:
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

// MARK: - Schema-aware parsing

extension Observation {

    /// Maps this observation onto its schema, producing typed values keyed by
    /// field path.
    ///
    /// - Parameters:
    ///   - schema: the DataRecord this observation was produced against.
    ///   - encoding: the module's BinaryEncoding, when available. Only used for
    ///     `.video` payloads, where it supplies the codec name that goes into
    ///     the resulting `.block` value — the schema alone does not carry it.
    func parsed(schema: DataRecord,
                encoding: BinaryEncoding? = nil) throws -> ParsedObservation {
        switch payload {
        case .scalar(let values):
            return try SchemaWalker.parsedObservation(datastreamId: datastreamName,
                                                      record: schema,
                                                      scalars: values)
        case .video(let timestamp, let frame):
            return try SchemaWalker.parsedObservation(datastreamId: datastreamName,
                                                      record: schema,
                                                      timestamp: timestamp,
                                                      frame: frame,
                                                      compression: encoding?.blockCompression)
        }
    }
}
