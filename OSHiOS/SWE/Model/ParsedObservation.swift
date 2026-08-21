import Foundation

// MARK: - ParsedObservation
//
// One observation mapped onto its schema: every leaf path carries a typed
// value, and `orderedPaths` preserves schema order so a UI renders the same
// rows in the same sequence every time (a dictionary alone would not).
//
// This is the type the future data viewer consumes. Nothing in it refers to a
// local sensor, so an observation fetched from an OSH node can be presented by
// exactly the same views as one produced on-device.

struct ParsedObservation: Sendable, Identifiable {
    let id: UUID
    /// Local datastream id, or the module's outputName when only that is known.
    let datastreamId: String
    let phenomenonTime: Date
    let values: [FieldPath: FieldValue]
    /// Leaf paths in schema order, for stable UI rendering.
    let orderedPaths: [FieldPath]

    init(id: UUID = UUID(),
         datastreamId: String,
         phenomenonTime: Date,
         values: [FieldPath: FieldValue],
         orderedPaths: [FieldPath]) {
        self.id = id
        self.datastreamId = datastreamId
        self.phenomenonTime = phenomenonTime
        self.values = values
        self.orderedPaths = orderedPaths
    }

    func value(at path: String) -> FieldValue? {
        values[FieldPath(path)]
    }

    func double(at path: String) -> Double? {
        value(at: path)?.asDouble
    }
}
