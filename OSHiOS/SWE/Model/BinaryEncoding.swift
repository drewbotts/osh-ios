import Foundation

// MARK: - BinaryEncoding
//
// Maps a DataRecord field path to its wire type. A `.block` member is what
// marks a datastream as large-binary (video): ObservationPublisher skips those
// modules and SensorCard renders them as a video tile rather than as rows.

enum BinaryFieldType: Sendable {
    case scalar(SWEDataType)
    case block(compression: String) // e.g. "H264", "JPEG"
}

struct BinaryFieldEncoding: Sendable {
    let ref: String           // "/fieldName" path
    let type: BinaryFieldType
}

struct BinaryEncoding: Sendable {
    var byteOrder: String = "bigEndian"
    var byteEncoding: String = "raw"
    var fields: [BinaryFieldEncoding]

    /// The compression code of the first block member, if any — the codec the
    /// frames on this datastream are encoded with.
    var blockCompression: String? {
        for field in fields {
            if case .block(let compression) = field.type { return compression }
        }
        return nil
    }

    /// True when this encoding carries a BinaryBlock member, i.e. observations
    /// are frame-sized binary rather than scalars.
    var hasBinaryBlock: Bool { blockCompression != nil }
}
