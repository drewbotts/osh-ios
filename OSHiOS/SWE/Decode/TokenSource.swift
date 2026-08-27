import Foundation

// MARK: - TokenSource
//
// The seam that lets one parser tree decode two wire formats.
//
// SWEParserTree walks a schema and asks for values in schema order; it never
// looks at bytes or at JSON. A TokenSource knows how to answer those requests
// for one representation — by path lookup for JSON, by sequential reads against
// a member table for binary. Adding a third format (swe+csv, say) means adding
// a source, not touching the tree.
//
// The reads are `mutating` because a binary source consumes as it goes: reading
// is not idempotent there, and modelling it as a pure lookup would hide that.

protocol TokenSource {

    mutating func readDouble(at path: FieldPath) throws -> Double
    mutating func readInt(at path: FieldPath) throws -> Int
    mutating func readBool(at path: FieldPath) throws -> Bool
    mutating func readString(at path: FieldPath) throws -> String
    mutating func readTime(at path: FieldPath) throws -> Date

    /// An opaque run of bytes — a compressed video frame — and its codec.
    mutating func readBlock(at path: FieldPath) throws -> (Data, compression: String?)

    /// Which alternative of a DataChoice this record carries, as an index into
    /// `itemNames`. Binary sends an index; JSON names the selected item.
    mutating func readChoiceSelector(at path: FieldPath, itemNames: [String]) throws -> Int

    /// True while another record remains to be read.
    var hasMoreRecords: Bool { get }

    /// Advances to the next record. Called before each record is walked.
    mutating func beginRecord()

    /// A timestamp carried by the envelope rather than by the record.
    ///
    /// om+json puts phenomenonTime beside the result rather than inside it, so
    /// a record with no Time field of its own still has a real time available.
    /// Sources that carry no envelope return nil.
    var externalTime: Date? { get }
}

extension TokenSource {
    var externalTime: Date? { nil }
}

// MARK: - Errors

enum TokenSourceError: Error, LocalizedError, Equatable {

    /// The path names nothing in this record.
    case missingValue(FieldPath)

    /// The value is present but is not the type the schema calls for.
    case typeMismatch(expected: String, at: FieldPath)

    /// A binary read ran past the end of the message.
    case truncated(at: FieldPath, needed: Int, available: Int)

    /// The binary encoding has no member describing this path, so there is no
    /// way to know how many bytes the value occupies.
    case noEncodingMember(FieldPath)

    /// A DataChoice selector did not name any of the choice's items.
    case unknownChoice(String, at: FieldPath)

    /// The payload cannot carry this kind of value at all — a JSON observation
    /// standing in for a compressed video frame, for instance.
    case unsupportedValue(String, at: FieldPath)

    var errorDescription: String? {
        switch self {
        case .missingValue(let path):
            return "No value at \(path)"
        case .typeMismatch(let expected, let path):
            return "Value at \(path) is not \(expected)"
        case .truncated(let path, let needed, let available):
            return "Message truncated at \(path): needed \(needed) bytes, \(available) remain"
        case .noEncodingMember(let path):
            return "Binary encoding has no member for \(path)"
        case .unknownChoice(let name, let path):
            return "\"\(name)\" at \(path) is not one of the choice's items"
        case .unsupportedValue(let detail, let path):
            return "Cannot read \(detail) at \(path)"
        }
    }
}
