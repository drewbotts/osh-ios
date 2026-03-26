import Foundation

// MARK: - OGC SWE Common property URI helpers

enum SWEConstants {
    static let propertyBaseURI = "http://sensorml.com/ont/swe/property/"
    static let refFrame_WGS84_HAE = "http://www.opengis.net/def/crs/EPSG/0/4979"
    static let refFrame_4326     = "http://www.opengis.net/def/crs/EPSG/0/4326"
    static let refFrame_ENU      = "http://www.opengis.net/def/crs/OGC/0/ENU"
    static let defCoef           = "http://sensorml.com/ont/swe/property/Coefficient"

    static func propertyURI(_ name: String) -> String {
        propertyBaseURI + name
    }
}

// MARK: - Data types mirror of SWE Common

// Data type URIs match BinaryComponentImpl.java constants in swe-common-core.
// The server parser uses endsWith() checks, but writing full URIs is required.
enum SWEDataType: String, Codable {
    case double  = "http://www.opengis.net/def/dataType/OGC/0/double"
    case float   = "http://www.opengis.net/def/dataType/OGC/0/float32"
    case int     = "http://www.opengis.net/def/dataType/OGC/0/signedInt"
    case short   = "http://www.opengis.net/def/dataType/OGC/0/signedShort"
    case byte    = "http://www.opengis.net/def/dataType/OGC/0/signedByte"
    case string  = "http://www.opengis.net/def/dataType/OGC/0/string"
    case blob    = "http://www.opengis.net/def/dataType/OGC/0/blob"
}

// MARK: - DataComponent hierarchy

/// A named field in a DataRecord.
struct DataField {
    let name: String
    let component: DataComponent
}

/// Base protocol for all SWE data components.
protocol DataComponent {
    var definition: String? { get }
    var label: String? { get }
}

/// Scalar numeric field (Quantity).
struct Quantity: DataComponent {
    var definition: String?
    var label: String?
    var description: String?
    var uom: String          // UCUM code, e.g. "deg", "m", "1"
    var dataType: SWEDataType = .double
    var axisId: String?
    var refFrame: String?
}

/// Text field.
struct SWEText: DataComponent {
    var definition: String?
    var label: String?
}

/// Time stamp field (ISO UTC).
struct TimeStamp: DataComponent {
    var definition: String? = "http://www.opengis.net/def/property/OGC/0/PhenomenonTime"
    var label: String? = "Phenomenon Time"
    var refFrame: String? = "http://www.opengis.net/def/trs/BIPM/0/UTC"
    var uomHref: String? = "http://www.opengis.net/def/uom/ISO-8601/0/Gregorian"
}

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

/// Integer count — used both as a standalone field and as a DataArray elementCount descriptor.
/// When used as elementCount: `axisID` and `value` are set; `name` is omitted in serialisation.
/// When used as a field:      `name` comes from the DataField; `axisID`/`value` are not set.
struct SWECount: DataComponent {
    var definition: String?
    var label: String?
    var axisID: String?
    var value: Int?   // fixed element count (used only in elementCount context)
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

// MARK: - BinaryEncoding

/// Maps DataRecord field path to its wire type.
enum BinaryFieldType {
    case scalar(SWEDataType)
    case block(compression: String) // e.g. "H264", "JPEG"
}

struct BinaryFieldEncoding {
    let ref: String           // "/fieldName" path
    let type: BinaryFieldType
}

struct BinaryEncoding {
    var byteOrder: String = "bigEndian"
    var byteEncoding: String = "raw"
    var fields: [BinaryFieldEncoding]
}

// MARK: - DataBlock

/// Holds actual observation values matching a DataRecord schema.
struct DataBlock {
    var timestamp: Double    // Unix time seconds (wall clock)
    var values: [String: Any] // keyed by field name
    var frameData: Data?     // for binary blob fields (video)
}
