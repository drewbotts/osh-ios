import Foundation

// MARK: - JSONTokenSource
//
// Reads the JSON observation formats. Three shapes arrive from a node and all
// three are detected in init rather than being selected by the caller, because
// the caller usually knows only which Accept header it sent — and the node's
// answer to that is not what the OGC schema suggests:
//
//   a) application/swe+json  → a BARE JSON ARRAY of record objects.
//      Not {"items": [...]}. The spec's collection envelope does not appear on
//      this endpoint at all.
//   b) application/om+json   → {"items":[{"phenomenonTime":…, "result":{…}}]}.
//      The time lives beside the result, so it is kept as the external time.
//   c) a single record object, which is what one WebSocket message carries.
//
// Values are looked up by path rather than consumed in order, so a node that
// reorders fields or omits an optional one does not shift every later value.

struct JSONTokenSource: TokenSource {

    /// One record and the envelope time that came with it, if any.
    private struct Record {
        let body: Any
        let time: Date?
    }

    private let records: [Record]
    private var index: Int = -1

    // MARK: Init

    init(data: Data) throws {
        let root = try JSONSerialization.jsonObject(with: data)
        self.records = Self.records(from: root)
    }

    /// Builds a source from an already-parsed JSON value.
    init(json: Any) {
        self.records = Self.records(from: json)
    }

    private static func records(from root: Any) -> [Record] {
        // (a) a bare array of swe+json records
        if let array = root as? [Any] {
            return array.map { Record(body: $0, time: nil) }
        }

        guard let object = root as? [String: Any] else { return [] }

        // (b) an om+json collection
        if let items = object["items"] as? [Any] {
            return items.map { item in
                guard let entry = item as? [String: Any] else {
                    return Record(body: item, time: nil)
                }
                return record(from: entry)
            }
        }

        // (c) a single observation, with or without the O&M envelope
        return [record(from: object)]
    }

    private static func record(from object: [String: Any]) -> Record {
        let time = (object["phenomenonTime"] as? String).flatMap(parseTime)
            ?? (object["resultTime"] as? String).flatMap(parseTime)
        if let result = object["result"] {
            return Record(body: result, time: time)
        }
        return Record(body: object, time: time)
    }

    // MARK: Record framing

    var hasMoreRecords: Bool { index + 1 < records.count }

    mutating func beginRecord() { index += 1 }

    var externalTime: Date? {
        records.indices.contains(index) ? records[index].time : nil
    }

    // MARK: Reads

    mutating func readDouble(at path: FieldPath) throws -> Double {
        let value = try value(at: path)
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let parsed = Double(string) { return parsed }
        throw TokenSourceError.typeMismatch(expected: "a number", at: path)
    }

    mutating func readInt(at path: FieldPath) throws -> Int {
        let value = try value(at: path)
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let parsed = Int(string) { return parsed }
        throw TokenSourceError.typeMismatch(expected: "an integer", at: path)
    }

    mutating func readBool(at path: FieldPath) throws -> Bool {
        let value = try value(at: path)
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            if let parsed = Bool(string) { return parsed }
            if let numeric = Double(string) { return numeric != 0 }
        }
        throw TokenSourceError.typeMismatch(expected: "a boolean", at: path)
    }

    mutating func readString(at path: FieldPath) throws -> String {
        let value = try value(at: path)
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        throw TokenSourceError.typeMismatch(expected: "a string", at: path)
    }

    mutating func readTime(at path: FieldPath) throws -> Date {
        let value = try value(at: path)
        if let string = value as? String {
            guard let date = Self.parseTime(string) else {
                throw TokenSourceError.typeMismatch(expected: "an ISO 8601 time", at: path)
            }
            return date
        }
        // A numeric time is epoch seconds — what this app's own writer emits
        // before it formats, and what some nodes send verbatim.
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        throw TokenSourceError.typeMismatch(expected: "a time", at: path)
    }

    mutating func readBlock(at path: FieldPath) throws -> (Data, compression: String?) {
        let value = try value(at: path)
        // The node substitutes a human-readable placeholder for a compressed
        // result rather than base64-encoding it, so a video datastream simply
        // cannot be read from JSON. Saying so beats returning empty Data that
        // a caller would render as a black frame.
        guard let string = value as? String,
              let decoded = Data(base64Encoded: string) else {
            throw TokenSourceError.unsupportedValue("a binary block from JSON", at: path)
        }
        return (decoded, compression: nil)
    }

    mutating func readChoiceSelector(at path: FieldPath, itemNames: [String]) throws -> Int {
        let value = try value(at: path)

        // A choice may arrive as the bare name of the selected item...
        if let name = value as? String {
            guard let index = itemNames.firstIndex(of: name) else {
                throw TokenSourceError.unknownChoice(name, at: path)
            }
            return index
        }

        // ...or, more usually, as an object whose one item-named key holds the
        // selected value. An explicit "choiceValue" key may sit alongside it.
        guard let object = value as? [String: Any] else {
            throw TokenSourceError.typeMismatch(expected: "a choice", at: path)
        }
        if let named = object["choiceValue"] as? String,
           let index = itemNames.firstIndex(of: named) {
            return index
        }
        for (index, name) in itemNames.enumerated() where object[name] != nil {
            return index
        }
        throw TokenSourceError.unknownChoice(object.keys.sorted().joined(separator: ","), at: path)
    }

    // MARK: Path lookup

    /// Resolves a path against the current record.
    ///
    /// Two shapes need special handling and both come from DataArray:
    ///  • an index component addresses a JSON array element;
    ///  • the element type's *name* has no JSON counterpart when the elements
    ///    are scalars — "/frequency_axis/3/frequency" must land on the number
    ///    at index 3, not look for a "frequency" key inside it. Reaching a
    ///    scalar with components still to consume therefore returns the scalar.
    private func value(at path: FieldPath) throws -> Any {
        guard records.indices.contains(index) else {
            throw TokenSourceError.missingValue(path)
        }

        var current: Any = records[index].body
        for (position, component) in path.components.enumerated() {
            if let object = current as? [String: Any] {
                guard let next = object[component] else {
                    throw TokenSourceError.missingValue(FieldPath(
                        components: Array(path.components.prefix(position + 1))))
                }
                current = next
            } else if let array = current as? [Any] {
                guard let arrayIndex = Int(component), array.indices.contains(arrayIndex) else {
                    throw TokenSourceError.missingValue(FieldPath(
                        components: Array(path.components.prefix(position + 1))))
                }
                current = array[arrayIndex]
            } else {
                // A scalar with path left over: the element-type name.
                return current
            }
        }

        if current is NSNull {
            throw TokenSourceError.missingValue(path)
        }
        return current
    }

    /// The number of elements in the JSON array at `path`, when there is one.
    /// A variable-size DataArray whose elementCount is unresolved gets its size
    /// from the payload itself.
    func arrayCount(at path: FieldPath) -> Int? {
        (try? value(at: path)).flatMap { ($0 as? [Any])?.count }
    }

    // MARK: Time parsing

    /// ISO 8601, with or without fractional seconds.
    ///
    /// Two formatters because ISO8601DateFormatter fails outright on a string
    /// whose fractional-seconds presence does not match its options, and a node
    /// writes both forms — "…:54.177Z" for an observation, "…:32Z" for a
    /// validTime bound.
    ///
    /// nonisolated(unsafe) for the same reason ConnectedSystemsClient shares
    /// one formatter: formatOptions are set once inside the initialiser and
    /// never mutated afterwards, and Foundation documents date(from:) as
    /// thread-safe for concurrent parsing. Allocating a pair per record would
    /// put two object allocations on the path of every observation in a live
    /// stream to buy nothing.
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseTime(_ string: String) -> Date? {
        if let date = fractionalFormatter.date(from: string) { return date }
        if let date = plainFormatter.date(from: string) { return date }
        // Some nodes write a bare epoch in a string field.
        if let seconds = Double(string) { return Date(timeIntervalSince1970: seconds) }
        return nil
    }
}
