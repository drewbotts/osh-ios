import Foundation

// MARK: - SensorCardKind
//
// Which body a SensorCard renders, decided purely from a DataRecord. No sensor
// class is consulted — that is the whole point: the same card renders a local
// GPS output today and a remote datastream tomorrow.
//
// Split out from the view so the decision is testable without SwiftUI.

enum SensorCardKind: Equatable, Sendable {
    /// A Location vector: show the fix rather than three anonymous numbers.
    case location(LocationPaths)
    /// A DataArray: frames, not values. Show resolution and encoder health.
    case video
    /// Anything else: one labelled row per non-time leaf, with a sparkline.
    case fields

    static func from(schema: DataRecord) -> SensorCardKind {
        if let paths = LocationPaths.resolve(in: schema) { return .location(paths) }
        if containsDataArray(schema) { return .video }
        return .fields
    }

    /// True when any leaf is a DataArray. A DataArray's wire form is a single
    /// binary block, which is what makes a stream frames rather than values.
    private static func containsDataArray(_ schema: DataRecord) -> Bool {
        SchemaWalker.leaves(of: schema).contains { $0.component is SWEDataArray }
    }
}
