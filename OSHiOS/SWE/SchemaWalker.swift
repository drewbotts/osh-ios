import Foundation

// MARK: - SchemaWalker
//
// The bridge between a SWE schema and observed values.
//
// Sensor modules emit a flat [Double] whose order is the schema's leaf order —
// that contract is what keeps ConnectedSystemsClient's ordered-string JSON
// builders correct, and it is the same contract used here to give each value a
// path and a type. Everything downstream (SensorLiveState, SensorCard, the
// future viewer) works from the result rather than from the sensor class, so a
// remote datastream and a local one render identically.
//
// A DataArray is one leaf, not a subtree: its wire form is a single BinaryBlock
// (a compressed frame), so walking into its million pixel components would
// describe a structure no observation ever carries field-by-field.

enum SchemaWalker {

    // MARK: Leaf discovery

    /// Walks a DataRecord depth-first and returns the ordered leaf paths
    /// (scalars, and DataArray treated as a single leaf for its root path).
    static func leafPaths(of record: DataRecord) -> [FieldPath] {
        leaves(of: record).map(\.path)
    }

    /// A leaf path together with the component that describes it.
    struct Leaf: Sendable {
        let path: FieldPath
        let component: DataComponent
    }

    /// Depth-first leaves of a record, in schema order.
    static func leaves(of record: DataRecord) -> [Leaf] {
        var result: [Leaf] = []
        collectLeaves(of: record, at: FieldPath(components: []), into: &result)
        return result
    }

    private static func collectLeaves(of component: DataComponent,
                                      at path: FieldPath,
                                      into result: inout [Leaf]) {
        switch component {
        case let record as DataRecord:
            for field in record.fields {
                collectLeaves(of: field.component,
                              at: path.appending(field.name),
                              into: &result)
            }
        case let vector as SWEVector:
            for coordinate in vector.coordinates {
                collectLeaves(of: coordinate.component,
                              at: path.appending(coordinate.name),
                              into: &result)
            }
        default:
            // Quantity, Time, Count, Text — and DataArray, deliberately opaque.
            result.append(Leaf(path: path, component: component))
        }
    }

    // MARK: Scalar observations

    /// Maps a flat [Double] produced by a local SensorModule onto the record's
    /// leaf paths. values[0] is the time field.
    ///
    /// - Throws: `SchemaWalkerError.valueCountMismatch` when the array length
    ///   does not match the schema's leaf count — a silent truncation there
    ///   would shift every later value onto the wrong field.
    static func parsedObservation(datastreamId: String,
                                  record: DataRecord,
                                  scalars: [Double]) throws -> ParsedObservation {
        let leaves = leaves(of: record)
        guard leaves.count == scalars.count else {
            throw SchemaWalkerError.valueCountMismatch(expected: leaves.count,
                                                       actual: scalars.count)
        }

        var values: [FieldPath: FieldValue] = [:]
        var paths: [FieldPath] = []
        var phenomenonTime: Date?

        for (leaf, scalar) in zip(leaves, scalars) {
            let value: FieldValue
            switch leaf.component {
            case is TimeStamp:
                let date = Date(timeIntervalSince1970: scalar)
                if phenomenonTime == nil { phenomenonTime = date }
                value = .time(date)
            case is SWECount:
                value = .int(Int(scalar))
            default:
                value = .double(scalar)
            }
            values[leaf.path] = value
            paths.append(leaf.path)
        }

        return ParsedObservation(datastreamId: datastreamId,
                                 phenomenonTime: phenomenonTime ?? Date(),
                                 values: values,
                                 orderedPaths: paths)
    }

    // MARK: Video observations

    /// Maps a compressed frame onto a video record: the time field plus a
    /// single `.block` at the DataArray's path.
    static func parsedObservation(datastreamId: String,
                                  record: DataRecord,
                                  timestamp: Double,
                                  frame: Data,
                                  compression: String?) throws -> ParsedObservation {
        let leaves = leaves(of: record)
        guard let arrayLeaf = leaves.first(where: { $0.component is SWEDataArray }) else {
            throw SchemaWalkerError.noBinaryArrayField
        }

        let date = Date(timeIntervalSince1970: timestamp)
        var values: [FieldPath: FieldValue] = [:]
        var paths: [FieldPath] = []

        for leaf in leaves {
            if leaf.component is TimeStamp {
                values[leaf.path] = .time(date)
                paths.append(leaf.path)
            } else if leaf.path == arrayLeaf.path {
                values[leaf.path] = .block(frame, compression: compression)
                paths.append(leaf.path)
            }
            // Any other leaf on a video record carries no per-frame value.
        }

        return ParsedObservation(datastreamId: datastreamId,
                                 phenomenonTime: date,
                                 values: values,
                                 orderedPaths: paths)
    }
}

// MARK: - Errors

enum SchemaWalkerError: Error, LocalizedError, Equatable {
    case valueCountMismatch(expected: Int, actual: Int)
    case noBinaryArrayField

    var errorDescription: String? {
        switch self {
        case .valueCountMismatch(let expected, let actual):
            return "Observation has \(actual) values but the schema has \(expected) leaf fields"
        case .noBinaryArrayField:
            return "Video observation but the schema has no DataArray field"
        }
    }
}
