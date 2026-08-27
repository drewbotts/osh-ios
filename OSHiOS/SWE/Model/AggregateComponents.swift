import Foundation

// MARK: - Aggregate SWE components
//
// Components that contain other components.
//
// SchemaWalker — the local-sensor path — descends through Vector and DataRecord
// and stops at a DataArray, because for the video output this app writes, the
// array's whole wire form is one BinaryBlock. The decode path (SWEParserTree)
// makes that same call per-datastream instead of per-type: it walks a DataArray
// element by element unless the binary encoding puts a Block at the array's own
// path, which is exactly how a node distinguishes a spectrum from a video frame.

/// Vector of scalar components.
struct SWEVector: DataComponent {
    var definition: String?
    var label: String?
    var description: String?
    var refFrame: String?
    var localFrame: String?
    var coordinates: [DataField]  // ordered coordinate components
    // ── decode-side additions ──
    var id: String?
    var optional: Bool = false
    var updatable: Bool = false
}

/// Record of heterogeneous named fields.
struct DataRecord: DataComponent {
    var definition: String?
    var label: String?
    var name: String
    var fields: [DataField]
    // ── decode-side additions ──
    var description: String?
    var id: String?
    var optional: Bool = false
    var updatable: Bool = false
}

/// Homogeneous array of repeated elements — maps to SWE Common DataArray.
/// `elementCount` describes the array size (and axis).
/// `elementType` is the component type of each element; `elementTypeName` is its JSON "name".
///
/// The size is not always in the schema. A node may inline a Count with a
/// `value` (a 1512-row image), or give the elementCount an `href` pointing at a
/// Count field elsewhere in the same record whose value arrives with each
/// observation (a spectrum whose length changes per frame). Both forms live in
/// `elementCount`; `SWEParserTree` is where the reference is resolved.
struct SWEDataArray: DataComponent {
    var definition: String?
    var label: String?
    var elementCount: SWECount
    var elementTypeName: String      // "name" written inside the elementType object
    var elementType: DataComponent   // the repeated element component
    // ── decode-side additions ──
    var description: String?
    var id: String?
    var optional: Bool = false
    var updatable: Bool = false
}

/// A DataArray carrying a coordinate frame — SWE Common Matrix.
struct SWEMatrix: DataComponent {
    var definition: String?
    var label: String?
    var elementCount: SWECount
    var elementTypeName: String
    var elementType: DataComponent
    var refFrame: String?
    var localFrame: String?
    var description: String?
    var id: String?
    var optional: Bool = false
    var updatable: Bool = false
}

/// Exclusive choice between named alternatives.
///
/// Exactly one item is present in any given record. On the wire the selection
/// arrives first — as an index in binary, as the sole key of an object in
/// JSON — and only the selected item's components follow.
struct SWEDataChoice: DataComponent {
    var definition: String?
    var label: String?
    var description: String?
    /// The Category describing the selector itself, when the schema names one.
    var choiceValue: SWECategory?
    var items: [DataField]
    var id: String?
    var optional: Bool = false
    var updatable: Bool = false
}

/// A geometry-valued component (GeoJSON-style geometry in a SWE record).
struct SWEGeometry: DataComponent {
    var definition: String?
    var label: String?
    var srs: String?
    var description: String?
    var id: String?
    var optional: Bool = false
    var updatable: Bool = false
}

// MARK: - Unresolved reference

/// A `{"href": "#someId"}` standing in for a component defined elsewhere.
///
/// The schema decoder cannot resolve these as it goes: a reference may point
/// forward to a component it has not read yet. It records the id and leaves the
/// node in place; SWEParserTree resolves every one against the schema's id
/// index and throws `unresolvedReference` for any that dangles.
struct SWEHref: DataComponent {
    var definition: String? { nil }
    var label: String? { nil }
    var description: String? { nil }
    let id: String?

    /// The referenced component's id, without the leading "#".
    let ref: String

    init(ref: String) {
        self.ref = ref.hasPrefix("#") ? String(ref.dropFirst()) : ref
        self.id = nil
    }
}
