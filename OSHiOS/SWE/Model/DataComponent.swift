import Foundation

// MARK: - SWE Common data types
//
// Data type URIs match BinaryComponentImpl.java constants in swe-common-core.
// The server parser uses endsWith() checks, but writing full URIs is required.
enum SWEDataType: String, Codable, Sendable {
    case double  = "http://www.opengis.net/def/dataType/OGC/0/double"
    case float   = "http://www.opengis.net/def/dataType/OGC/0/float32"
    case int     = "http://www.opengis.net/def/dataType/OGC/0/signedInt"
    case short   = "http://www.opengis.net/def/dataType/OGC/0/signedShort"
    case byte    = "http://www.opengis.net/def/dataType/OGC/0/signedByte"
    case string  = "http://www.opengis.net/def/dataType/OGC/0/string"
    case blob    = "http://www.opengis.net/def/dataType/OGC/0/blob"
}

// MARK: - DataComponent

/// Base protocol for all SWE data components.
///
/// Sendable: schemas are immutable value descriptions that are handed to the
/// ConnectedSystemsClient actor and the ObservationPublisher actor, so the
/// existential must carry the guarantee. Every conforming type is a struct of
/// Sendable members and picks the conformance up implicitly.
protocol DataComponent: Sendable {
    var definition: String? { get }
    var label: String? { get }
}

/// A named field in a DataRecord (or a named coordinate in a Vector).
struct DataField: Sendable {
    let name: String
    let component: DataComponent
}
