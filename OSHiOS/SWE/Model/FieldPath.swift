import Foundation

// MARK: - FieldPath
//
// A slash-delimited path to one leaf inside a DataRecord, e.g. "/location/lat".
// This is the same notation BinaryEncoding members use in their `ref`, so a
// path produced by SchemaWalker can be matched against an encoding directly.
//
// Leading and repeated separators are ignored on the way in, so
// FieldPath("/location/lat"), FieldPath("location/lat") and
// FieldPath(components: ["location", "lat"]) are all the same value.

struct FieldPath: Hashable, Sendable, CustomStringConvertible {

    /// The path segments, outermost first. Never contains empty strings.
    let components: [String]

    init(_ string: String) {
        self.components = string.split(separator: "/").map(String.init)
    }

    init(components: [String]) {
        self.components = components.filter { !$0.isEmpty }
    }

    /// A new path one level deeper.
    func appending(_ name: String) -> FieldPath {
        FieldPath(components: components + [name])
    }

    /// The leaf segment — the field's own name. Empty for the root path.
    var lastComponent: String { components.last ?? "" }

    /// The slash form, always with a leading separator: "/location/lat".
    /// The root path renders as "/".
    var description: String { "/" + components.joined(separator: "/") }
}
