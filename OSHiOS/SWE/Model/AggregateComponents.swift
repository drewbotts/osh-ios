import Foundation

// MARK: - Aggregate SWE components
//
// Components that contain other components. SchemaWalker descends through
// Vector and DataRecord; a DataArray is treated as one opaque leaf because its
// wire form is a single binary block (see BinaryEncoding).

/// Vector of scalar components.
struct SWEVector: DataComponent {
    var definition: String?
    var label: String?
    var description: String?
    var refFrame: String?
    var localFrame: String?
    var coordinates: [DataField]  // ordered coordinate components
}

/// Record of heterogeneous named fields.
struct DataRecord: DataComponent {
    var definition: String?
    var label: String?
    var name: String
    var fields: [DataField]
}

/// Homogeneous array of repeated elements — maps to SWE Common DataArray.
/// `elementCount` describes the array size (and axis).
/// `elementType` is the component type of each element; `elementTypeName` is its JSON "name".
struct SWEDataArray: DataComponent {
    var definition: String?
    var label: String?
    var elementCount: SWECount
    var elementTypeName: String      // "name" written inside the elementType object
    var elementType: DataComponent   // the repeated element component
}
