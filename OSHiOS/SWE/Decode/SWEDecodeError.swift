import Foundation

// MARK: - SWEDecodeError
//
// Every case carries the path of the component that failed. A schema decode
// error on a real node is otherwise almost undiagnosable — the documents run to
// hundreds of lines and the failure is always one field deep inside one of
// them — so the path is the difference between a Logs tab entry that names the
// culprit and one that says only "invalid value".

enum SWEDecodeError: Error, LocalizedError, Equatable {

    /// A "type" this decoder does not implement.
    case unsupportedComponent(String, FieldPath)

    /// A key the SWE schema requires for this component type is absent.
    case missingKey(String, FieldPath)

    /// A key is present but holds something unusable.
    case invalidValue(String, FieldPath)

    /// An href pointed at an id that no component in the document declares.
    case unresolvedReference(String)

    /// The document is not a datastream schema at all.
    case malformedTopLevel(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedComponent(let type, let path):
            return "Unsupported SWE component type \"\(type)\" at \(path)"
        case .missingKey(let key, let path):
            return "Missing required key \"\(key)\" at \(path)"
        case .invalidValue(let detail, let path):
            return "Invalid value at \(path): \(detail)"
        case .unresolvedReference(let ref):
            return "Reference \"#\(ref)\" does not resolve to any component in the schema"
        case .malformedTopLevel(let detail):
            return "Malformed schema document: \(detail)"
        }
    }
}
