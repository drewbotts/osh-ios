import Foundation

// MARK: - OrderedJSON
//
// A JSON document that remembers the order its keys were written in.
//
// Foundation's JSONSerialization reads an object into a Dictionary, and a
// Dictionary has no order. That is fine for everything this app *reads* — the
// Codable models do not care where a key sits — and fatal for anything it has to
// send back: the node parses SensorML and SWE JSON with a streaming reader that
// requires `type` to be the first key of every object it opens, and re-emitting
// a Dictionary would put `type` wherever hashing happened to leave it.
//
// Every JSON builder this app already has (SystemDescriptor, CommandBody, the
// observation builders) sidesteps the problem by writing strings in a fixed
// order. Survey-in cannot: it has to *edit* a document the node wrote, keeping
// every key it did not touch exactly where the node put it. Hence a small value
// tree that keeps members in an array, and a parser and serialiser that do not
// reorder anything.
//
// Numbers are kept as the text they arrived as. `34.99950637619338` written by
// the node must go back as `34.99950637619338`, not as whatever Double's
// shortest-round-trip formatting decides, so that an unedited document
// serialises to the same digits it was read from.

indirect enum OrderedJSON: Equatable, Sendable {

    /// One key/value pair of an object, in document order.
    struct Member: Equatable, Sendable {
        var key: String
        var value: OrderedJSON

        init(_ key: String, _ value: OrderedJSON) {
            self.key = key
            self.value = value
        }
    }

    case object([Member])
    case array([OrderedJSON])
    case string(String)
    /// The number exactly as written — see the header.
    case number(String)
    case bool(Bool)
    case null

    // MARK: Reading

    var members: [Member]? {
        if case .object(let members) = self { return members }
        return nil
    }

    var elements: [OrderedJSON]? {
        if case .array(let elements) = self { return elements }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let lexeme) = self { return Double(lexeme) }
        return nil
    }

    /// The value for `key` in an object; nil for a missing key or a non-object.
    subscript(key: String) -> OrderedJSON? {
        members?.first { $0.key == key }?.value
    }

    /// The keys of an object, in order.
    var keys: [String] { members?.map(\.key) ?? [] }

    // MARK: Editing

    /// A copy with `key` set to `value`.
    ///
    /// An existing member is replaced in place, so its position is kept. A new
    /// one is inserted directly after the *last* member whose key appears in
    /// `anchors`; when none of them is present it is appended. Only meaningful
    /// on an object — any other value is returned unchanged.
    func setting(_ key: String, to value: OrderedJSON, insertingAfter anchors: [String]) -> OrderedJSON {
        guard var members = members else { return self }

        if let index = members.firstIndex(where: { $0.key == key }) {
            members[index].value = value
            return .object(members)
        }

        let anchorSet = Set(anchors)
        if let last = members.lastIndex(where: { anchorSet.contains($0.key) }) {
            members.insert(Member(key, value), at: last + 1)
        } else {
            members.append(Member(key, value))
        }
        return .object(members)
    }

    /// A copy without `key`. Unchanged when absent or not an object.
    func removing(_ key: String) -> OrderedJSON {
        guard let members else { return self }
        return .object(members.filter { $0.key != key })
    }

    // MARK: Convenience constructors

    static func number(_ value: Double) -> OrderedJSON {
        .number(CommandBody.number(value))
    }

    // MARK: Serialising

    /// Compact JSON, members in order, numbers as their lexemes.
    func serialized() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    func serializedData() -> Data {
        Data(serialized().utf8)
    }

    private func write(into out: inout String) {
        switch self {
        case .object(let members):
            out += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { out += "," }
                out += CommandBody.string(member.key)
                out += ":"
                member.value.write(into: &out)
            }
            out += "}"

        case .array(let elements):
            out += "["
            for (index, element) in elements.enumerated() {
                if index > 0 { out += "," }
                element.write(into: &out)
            }
            out += "]"

        case .string(let value):
            out += CommandBody.string(value)

        case .number(let lexeme):
            out += lexeme

        case .bool(let value):
            out += value ? "true" : "false"

        case .null:
            out += "null"
        }
    }

    // MARK: Parsing

    static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }

    static func parse(_ text: String) throws -> OrderedJSON {
        try parse(Data(text.utf8))
    }
}

// MARK: - Errors

enum OrderedJSONError: Error, LocalizedError, Equatable {
    case unexpectedEnd
    case unexpectedCharacter(String, offset: Int)
    case invalidNumber(String, offset: Int)
    case invalidEscape(offset: Int)
    case invalidUTF8(offset: Int)
    case trailingContent(offset: Int)

    var errorDescription: String? {
        switch self {
        case .unexpectedEnd:
            return "JSON ended unexpectedly"
        case .unexpectedCharacter(let character, let offset):
            return "Unexpected '\(character)' at byte \(offset)"
        case .invalidNumber(let lexeme, let offset):
            return "Invalid number '\(lexeme)' at byte \(offset)"
        case .invalidEscape(let offset):
            return "Invalid escape sequence at byte \(offset)"
        case .invalidUTF8(let offset):
            return "Invalid UTF-8 in string ending at byte \(offset)"
        case .trailingContent(let offset):
            return "Unexpected content after the document at byte \(offset)"
        }
    }
}

// MARK: - Parser

/// A recursive-descent parser over the raw bytes.
///
/// Deliberately minimal — RFC 8259, nothing more — because it only ever reads
/// what one particular server wrote, and every leniency is a place where a
/// document could be reproduced differently from how it arrived.
private struct Parser {

    let bytes: [UInt8]
    var index = 0

    mutating func parseDocument() throws -> OrderedJSON {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else {
            throw OrderedJSONError.trailingContent(offset: index)
        }
        return value
    }

    private mutating func parseValue() throws -> OrderedJSON {
        guard index < bytes.count else { throw OrderedJSONError.unexpectedEnd }
        switch bytes[index] {
        case UInt8(ascii: "{"):  return try parseObject()
        case UInt8(ascii: "["):  return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"):  try expect("true");  return .bool(true)
        case UInt8(ascii: "f"):  try expect("false"); return .bool(false)
        case UInt8(ascii: "n"):  try expect("null");  return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try parseNumber()
        default:
            throw unexpected()
        }
    }

    private mutating func parseObject() throws -> OrderedJSON {
        index += 1 // {
        var members: [OrderedJSON.Member] = []
        skipWhitespace()
        if try peek() == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard try peek() == UInt8(ascii: "\"") else { throw unexpected() }
            let key = try parseString()
            skipWhitespace()
            guard try peek() == UInt8(ascii: ":") else { throw unexpected() }
            index += 1
            skipWhitespace()
            let value = try parseValue()
            members.append(OrderedJSON.Member(key, value))
            skipWhitespace()
            switch try peek() {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"): index += 1; return .object(members)
            default: throw unexpected()
            }
        }
    }

    private mutating func parseArray() throws -> OrderedJSON {
        index += 1 // [
        var elements: [OrderedJSON] = []
        skipWhitespace()
        if try peek() == UInt8(ascii: "]") {
            index += 1
            return .array(elements)
        }
        while true {
            skipWhitespace()
            elements.append(try parseValue())
            skipWhitespace()
            switch try peek() {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"): index += 1; return .array(elements)
            default: throw unexpected()
            }
        }
    }

    private mutating func parseString() throws -> String {
        index += 1 // opening quote
        var out: [UInt8] = []
        while true {
            guard index < bytes.count else { throw OrderedJSONError.unexpectedEnd }
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                guard let string = String(bytes: out, encoding: .utf8) else {
                    throw OrderedJSONError.invalidUTF8(offset: index)
                }
                return string

            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else { throw OrderedJSONError.unexpectedEnd }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"):  out.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"):  out.append(0x08)
                case UInt8(ascii: "f"):  out.append(0x0C)
                case UInt8(ascii: "n"):  out.append(0x0A)
                case UInt8(ascii: "r"):  out.append(0x0D)
                case UInt8(ascii: "t"):  out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalarValue = try parseHex4()
                    // A high surrogate must be followed by an escaped low one;
                    // the pair is one scalar.
                    if (0xD800...0xDBFF).contains(scalarValue) {
                        guard index + 1 < bytes.count,
                              bytes[index] == UInt8(ascii: "\\"),
                              bytes[index + 1] == UInt8(ascii: "u") else {
                            throw OrderedJSONError.invalidEscape(offset: index)
                        }
                        index += 2
                        let low = try parseHex4()
                        guard (0xDC00...0xDFFF).contains(low) else {
                            throw OrderedJSONError.invalidEscape(offset: index)
                        }
                        scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = UnicodeScalar(scalarValue) else {
                        throw OrderedJSONError.invalidEscape(offset: index)
                    }
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    throw OrderedJSONError.invalidEscape(offset: index)
                }

            default:
                if byte < 0x20 { throw unexpected() }
                out.append(byte)
                index += 1
            }
        }
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw OrderedJSONError.unexpectedEnd }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A")) + 10
            default: throw OrderedJSONError.invalidEscape(offset: index)
            }
            value = value * 16 + digit
            index += 1
        }
        return value
    }

    private mutating func parseNumber() throws -> OrderedJSON {
        let start = index
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "+"),
                 UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"):
                index += 1
            default:
                break
            }
            if index < bytes.count, !Self.isNumberByte(bytes[index]) { break }
        }
        let lexeme = String(decoding: bytes[start..<index], as: UTF8.self)
        // Double() is a stricter grammar check than the byte scan above, and
        // the lexeme is what gets written back, so it must at least be a number.
        guard Double(lexeme) != nil, !lexeme.hasPrefix("+"), !lexeme.hasSuffix(".") else {
            throw OrderedJSONError.invalidNumber(lexeme, offset: start)
        }
        return .number(lexeme)
    }

    private static func isNumberByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "+"),
             UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"):
            return true
        default:
            return false
        }
    }

    private mutating func expect(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count else { throw OrderedJSONError.unexpectedEnd }
        guard Array(bytes[index..<index + expected.count]) == expected else { throw unexpected() }
        index += expected.count
    }

    private func peek() throws -> UInt8 {
        guard index < bytes.count else { throw OrderedJSONError.unexpectedEnd }
        return bytes[index]
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private func unexpected() -> OrderedJSONError {
        guard index < bytes.count else { return .unexpectedEnd }
        return .unexpectedCharacter(String(UnicodeScalar(bytes[index])), offset: index)
    }
}
