import Foundation

// MARK: - Scalar SWE components
//
// The leaf component types: a value lands on exactly one of these when an
// observation is mapped onto its schema (see SchemaWalker).

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

/// Integer count — used both as a standalone field and as a DataArray elementCount descriptor.
/// When used as elementCount: `axisID` and `value` are set; `name` is omitted in serialisation.
/// When used as a field:      `name` comes from the DataField; `axisID`/`value` are not set.
struct SWECount: DataComponent {
    var definition: String?
    var label: String?
    var axisID: String?
    var value: Int?   // fixed element count (used only in elementCount context)
}
