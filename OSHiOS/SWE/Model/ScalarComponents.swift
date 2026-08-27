import Foundation

// MARK: - Scalar SWE components
//
// The leaf component types: a value lands on exactly one of these when an
// observation is mapped onto its schema (see SchemaWalker) or decoded from a
// node (see SWEParserTree).
//
// Every type here was extended in Pass 3a rather than replaced. New members are
// appended with defaults, never inserted, because the encoder's builders call
// the memberwise initialisers positionally — inserting a property in the middle
// would silently change what an existing call site means.

/// Scalar numeric field (Quantity).
struct Quantity: DataComponent {
    var definition: String?
    var label: String?
    var description: String?
    var uom: String          // UCUM code, e.g. "deg", "m", "1"
    var dataType: SWEDataType = .double
    var axisId: String?
    var refFrame: String?
    // ── decode-side additions ──
    var uomHref: String?
    var constraint: AllowedValues?
    var nilValues: [NilValue]?
    var id: String?
    var optional: Bool = false
    var updatable: Bool = false
}

/// Text field — free-form string, no controlled vocabulary.
struct SWEText: DataComponent {
    var definition: String?
    var label: String?
    // ── decode-side additions ──
    var description: String?
    var constraint: AllowedTokens?
    var nilValues: [NilValue]?
    var id: String?
    var optional: Bool = false
    var updatable: Bool = false
}

/// Category field — a token drawn from a controlled vocabulary.
///
/// Distinct from Text in intent rather than in wire form: both are strings, but
/// a Category's `codeSpace` names the dictionary its token comes from, which is
/// what lets a viewer resolve "1" to "Scheduled position report".
struct SWECategory: DataComponent {
    var definition: String?
    var label: String?
    var description: String?
    var codeSpace: String?
    var constraint: AllowedTokens?
    var nilValues: [NilValue]?
    var id: String?
    var optional: Bool = false
    var updatable: Bool = false
}

/// Boolean field.
struct SWEBoolean: DataComponent {
    var definition: String?
    var label: String?
    var description: String?
    var id: String?
    var optional: Bool = false
    var updatable: Bool = false
}

/// Time stamp field (ISO UTC) — the form this app writes for its own outputs.
///
/// Kept exactly as it was: the datastream registration builders construct it
/// with no arguments and rely on every default here.
struct TimeStamp: DataComponent {
    var definition: String? = "http://www.opengis.net/def/property/OGC/0/PhenomenonTime"
    var label: String? = "Phenomenon Time"
    var refFrame: String? = "http://www.opengis.net/def/trs/BIPM/0/UTC"
    var uomHref: String? = "http://www.opengis.net/def/uom/ISO-8601/0/Gregorian"
    // ── decode-side additions ──
    var description: String?
    var id: String?
    var optional: Bool = false
    var updatable: Bool = false
}

/// General SWE Time component.
///
/// The counterpart to TimeStamp for schemas this app did not write. A node's
/// Time may be a sampling time, a sensor uptime, a validity instant or anything
/// else its definition says it is, so nothing here is defaulted.
struct SWETime: DataComponent {
    var definition: String?
    var label: String?
    var description: String?
    var refFrame: String?
    var uomHref: String?
    var localFrame: String?
    var constraint: AllowedValues?
    var nilValues: [NilValue]?
    var id: String?
    var optional: Bool = false
    var updatable: Bool = false
}

// MARK: - Phenomenon time

/// Whether a Time component is the record's phenomenon time.
///
/// The property URI is the interoperable signal, and nodes use two spellings
/// for the same idea: OGC's PhenomenonTime and the older SamplingTime, which
/// every driver on the reference node emits instead. Both count.
protocol TimeComponent: DataComponent {
    var isPhenomenonTime: Bool { get }
}

private func definitionIsPhenomenonTime(_ definition: String?) -> Bool {
    guard let definition else { return false }
    return definition.localizedCaseInsensitiveContains("PhenomenonTime")
        || definition.localizedCaseInsensitiveContains("SamplingTime")
        || definition.localizedCaseInsensitiveContains("SampleTime")
}

extension TimeStamp: TimeComponent {
    var isPhenomenonTime: Bool { definitionIsPhenomenonTime(definition) }
}

extension SWETime: TimeComponent {
    var isPhenomenonTime: Bool { definitionIsPhenomenonTime(definition) }
}

/// Integer count — used both as a standalone field and as a DataArray elementCount descriptor.
/// When used as elementCount: `axisID` and `value` are set; `name` is omitted in serialisation.
/// When used as a field:      `name` comes from the DataField; `axisID`/`value` are not set.
struct SWECount: DataComponent {
    var definition: String?
    var label: String?
    var axisID: String?
    var value: Int?   // fixed element count (used only in elementCount context)
    // ── decode-side additions ──
    var description: String?
    /// Set when an elementCount is `{"href": "#someId"}` rather than an inline
    /// Count: the id of the Count component elsewhere in the record that
    /// carries the real size. Resolved when the parser tree is built.
    var ref: String?
    var constraint: AllowedValues?
    var nilValues: [NilValue]?
    var id: String?
    var optional: Bool = false
    var updatable: Bool = false
}

// MARK: - Range components
//
// Two-value variants carrying the same metadata as their scalar forms. A range
// occupies two slots on the wire, not one — the parser tree emits a lower and
// an upper leaf under the component's own path.

/// Numeric interval.
struct QuantityRange: DataComponent {
    var definition: String?
    var label: String?
    var description: String?
    var uom: String
    var dataType: SWEDataType = .double
    var axisId: String?
    var refFrame: String?
    var uomHref: String?
    var constraint: AllowedValues?
    var nilValues: [NilValue]?
    var id: String?
    var optional: Bool = false
    var updatable: Bool = false
}

/// Integer interval.
struct CountRange: DataComponent {
    var definition: String?
    var label: String?
    var description: String?
    var constraint: AllowedValues?
    var nilValues: [NilValue]?
    var id: String?
    var optional: Bool = false
    var updatable: Bool = false
}

/// Interval between two tokens of a controlled vocabulary.
struct CategoryRange: DataComponent {
    var definition: String?
    var label: String?
    var description: String?
    var codeSpace: String?
    var constraint: AllowedTokens?
    var nilValues: [NilValue]?
    var id: String?
    var optional: Bool = false
    var updatable: Bool = false
}

/// Time interval.
struct TimeRange: DataComponent {
    var definition: String?
    var label: String?
    var description: String?
    var refFrame: String?
    var uomHref: String?
    var localFrame: String?
    var constraint: AllowedValues?
    var nilValues: [NilValue]?
    var id: String?
    var optional: Bool = false
    var updatable: Bool = false
}
