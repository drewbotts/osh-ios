import Foundation

// MARK: - SWE Common data types
//
// Data type URIs match BinaryComponentImpl.java constants in swe-common-core.
// The server parser uses endsWith() checks, but writing full URIs is required.
//
// The decode-side cases were added in Pass 3a from the dataTypes a live node
// actually emits in a BinaryEncoding. Two of those spellings are worth calling
// out because guessing them wrong is silent corruption rather than an error:
// UTF-8 text is "string-utf-8" (not "utf8String"), and booleans are "boolean".
enum SWEDataType: String, Codable, Sendable, CaseIterable {
    case double        = "http://www.opengis.net/def/dataType/OGC/0/double"
    case float         = "http://www.opengis.net/def/dataType/OGC/0/float32"
    case int           = "http://www.opengis.net/def/dataType/OGC/0/signedInt"
    case short         = "http://www.opengis.net/def/dataType/OGC/0/signedShort"
    case byte          = "http://www.opengis.net/def/dataType/OGC/0/signedByte"
    case string        = "http://www.opengis.net/def/dataType/OGC/0/string"
    case blob          = "http://www.opengis.net/def/dataType/OGC/0/blob"
    case unsignedInt   = "http://www.opengis.net/def/dataType/OGC/0/unsignedInt"
    case unsignedShort = "http://www.opengis.net/def/dataType/OGC/0/unsignedShort"
    case unsignedByte  = "http://www.opengis.net/def/dataType/OGC/0/unsignedByte"
    case signedLong    = "http://www.opengis.net/def/dataType/OGC/0/signedLong"
    case unsignedLong  = "http://www.opengis.net/def/dataType/OGC/0/unsignedLong"
    case boolean       = "http://www.opengis.net/def/dataType/OGC/0/boolean"
    case utf8String    = "http://www.opengis.net/def/dataType/OGC/0/string-utf-8"

    /// Matches a dataType URI by its last path component, case-insensitively.
    ///
    /// Nodes are inconsistent about the prefix — the same type appears as
    /// ".../def/dataType/OGC/0/double" and as a bare "double" depending on the
    /// writer — so only the suffix is dependable. A full URI is accepted too,
    /// which makes this a safe replacement for `init(rawValue:)` everywhere.
    static func from(uriSuffix uri: String) -> SWEDataType? {
        let suffix = uri.split(separator: "/").last.map(String.init) ?? uri
        return allCases.first {
            $0.rawValue.split(separator: "/").last?.compare(
                suffix, options: .caseInsensitive) == .orderedSame
        }
    }

    /// Fixed width in bytes, or nil for the variable-length types (text, blob).
    var byteWidth: Int? {
        switch self {
        case .double, .signedLong, .unsignedLong: return 8
        case .float, .int, .unsignedInt:          return 4
        case .short, .unsignedShort:              return 2
        case .byte, .unsignedByte, .boolean:      return 1
        case .string, .utf8String, .blob:         return nil
        }
    }
}

// MARK: - DataComponent

/// Base protocol for all SWE data components.
///
/// Sendable: schemas are immutable value descriptions that are handed to the
/// ConnectedSystemsClient actor and the ObservationPublisher actor, so the
/// existential must carry the guarantee. Every conforming type is a struct of
/// Sendable members and picks the conformance up implicitly.
///
/// `id` and `description` are protocol requirements rather than per-type extras
/// because the schema decoder needs them uniformly: `id` is what an
/// elementCount `href` or a `#ref` resolves against, and `description` is the
/// only human-readable text some node components carry.
protocol DataComponent: Sendable {
    var definition: String? { get }
    var label: String? { get }
    var description: String? { get }
    var id: String? { get }
}

/// A named field in a DataRecord (or a named coordinate in a Vector).
struct DataField: Sendable {
    let name: String
    let component: DataComponent
}
