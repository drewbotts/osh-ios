import Foundation

// MARK: - DataBlock

/// Holds actual observation values matching a DataRecord schema.
///
/// The untyped counterpart to ParsedObservation, kept for parity with the
/// Android driver's DataBlock. New code should prefer ParsedObservation, whose
/// values are keyed by FieldPath and carry a typed FieldValue.
struct DataBlock {
    var timestamp: Double    // Unix time seconds (wall clock)
    var values: [String: Any] // keyed by field name
    var frameData: Data?     // for binary blob fields (video)
}
