import Foundation

// MARK: - FieldValue
//
// One observed value, typed by what its schema component says it is. Sensor
// modules hand SensorSession a flat [Double]; SchemaWalker turns that into
// FieldValues so the UI can format a time as a date, a count as an integer and
// a DataArray as an opaque blob without re-deriving any of it from the schema.

enum FieldValue: Sendable, Equatable {
    case double(Double)
    case int(Int)
    case bool(Bool)
    case text(String)
    case time(Date)
    /// A binary block — a compressed video frame and its codec ("H264", "JPEG").
    case block(Data, compression: String?)

    /// The value as a Double where that is meaningful: numbers as themselves,
    /// a time as seconds since the Unix epoch. nil for text, bool and blocks.
    var asDouble: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i):    return Double(i)
        case .time(let d):   return d.timeIntervalSince1970
        case .bool, .text, .block: return nil
        }
    }

    /// A short display form suitable for a value label.
    var asString: String {
        switch self {
        case .double(let d): return String(format: "%g", d)
        case .int(let i):    return String(i)
        case .bool(let b):   return b ? "true" : "false"
        case .text(let s):   return s
        case .time(let d):   return d.ISO8601Format(.init(includingFractionalSeconds: true))
        case .block(let data, let compression):
            let codec = compression ?? "binary"
            return "\(codec) · \(data.count) B"
        }
    }
}
