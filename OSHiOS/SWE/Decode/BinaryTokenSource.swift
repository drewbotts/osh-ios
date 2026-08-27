import Foundation

// MARK: - BinaryTokenSource
//
// Reads application/swe+binary: a cursor over the message bytes, driven by the
// encoding's member table.
//
// Binary is positional — nothing in the stream names a field — so a value is
// whatever the schema says comes next, and a wrong width is silent corruption
// rather than an error. That is why every read consults the member table for
// its path instead of inferring a width from the component type, and why every
// read is bounds-checked: a short read would decode to a plausible wrong number
// and shift every later field.
//
// The layouts here were verified byte-for-byte against messages captured from a
// live node. See BINARY_FORMAT.md for the table and what each row was verified
// against — including the one row that could not be verified.

struct BinaryTokenSource: TokenSource {

    private let data: Data
    private let encoding: DecodedBinaryEncoding
    private var offset: Int

    /// Byte offset at which the current record began.
    private(set) var recordStart: Int

    /// - Parameters:
    ///   - data: one or more concatenated records.
    ///   - encoding: the datastream's decoded BinaryEncoding.
    ///
    /// A byteEncoding of "base64" means the whole message is base64 text rather
    /// than raw bytes, so it is decoded once here and every read afterwards
    /// sees ordinary bytes.
    init(data: Data, encoding: DecodedBinaryEncoding) {
        if encoding.byteEncoding.compare("base64", options: .caseInsensitive) == .orderedSame,
           let text = String(data: data, encoding: .utf8),
           let decoded = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines),
                              options: .ignoreUnknownCharacters) {
            self.data = decoded
        } else {
            self.data = data
        }
        self.encoding = encoding
        self.offset = 0
        self.recordStart = 0
    }

    // MARK: Record framing

    var hasMoreRecords: Bool { offset < data.count }

    mutating func beginRecord() { recordStart = offset }

    var externalTime: Date? { nil }

    // MARK: Scalars

    mutating func readDouble(at path: FieldPath) throws -> Double {
        switch try dataType(at: path) {
        case .double:  return Double(bitPattern: try readUInt(8, at: path))
        case .float:   return Double(Float(bitPattern: UInt32(truncatingIfNeeded: try readUInt(4, at: path))))
        case .boolean: return try readByte(at: path) != 0 ? 1 : 0
        case .string, .utf8String:
            // A node is free to declare a numeric component as text.
            guard let value = Double(try readText(at: path)) else {
                throw SWEDecodeError.invalidValue("text is not a number", path)
            }
            return value
        case .blob:
            throw SWEDecodeError.invalidValue("a blob cannot be read as a number", path)
        case let type:
            return Double(try readIntegral(type, at: path))
        }
    }

    mutating func readInt(at path: FieldPath) throws -> Int {
        switch try dataType(at: path) {
        case .double:  return Int(Double(bitPattern: try readUInt(8, at: path)))
        case .float:   return Int(Float(bitPattern: UInt32(truncatingIfNeeded: try readUInt(4, at: path))))
        case .boolean: return try readByte(at: path) != 0 ? 1 : 0
        case .string, .utf8String:
            guard let value = Int(try readText(at: path)) else {
                throw SWEDecodeError.invalidValue("text is not an integer", path)
            }
            return value
        case .blob:
            throw SWEDecodeError.invalidValue("a blob cannot be read as an integer", path)
        case let type:
            return try readIntegral(type, at: path)
        }
    }

    mutating func readBool(at path: FieldPath) throws -> Bool {
        let type = try dataType(at: path)
        guard type == .boolean else { return try readIntegral(type, at: path) != 0 }
        return try readByte(at: path) != 0
    }

    mutating func readString(at path: FieldPath) throws -> String {
        _ = try dataType(at: path)
        return try readText(at: path)
    }

    /// Epoch seconds from a double, epoch milliseconds from a signedLong.
    ///
    /// The two are indistinguishable from the value alone — 1.78e9 is a
    /// plausible instant in seconds and a plausible instant in milliseconds
    /// 55 years apart — so the dataType, not a magnitude heuristic, decides.
    mutating func readTime(at path: FieldPath) throws -> Date {
        switch try dataType(at: path) {
        case .signedLong, .unsignedLong:
            let millis = try readIntegral(try dataType(at: path), at: path)
            return Date(timeIntervalSince1970: Double(millis) / 1000)
        default:
            return Date(timeIntervalSince1970: try readDouble(at: path))
        }
    }

    // MARK: Blocks

    mutating func readBlock(at path: FieldPath) throws -> (Data, compression: String?) {
        guard let member = encoding.member(for: path),
              case .block(let compression, _, let declaredLength,
                          let padBefore, let padAfter) = member.kind else {
            throw SWEDecodeError.invalidValue("no Block member for this path", path)
        }

        if let padBefore { _ = try take(padBefore, at: path) }

        // A Block with no declared byteLength is length-prefixed on the wire,
        // in the encoding's byte order — which is what every video datastream
        // on the reference node does.
        let length = try declaredLength ?? Int(readUInt(4, at: path))
        let payload = try take(length, at: path)

        if let padAfter { _ = try take(padAfter, at: path) }

        return (Data(payload), compression: compression)
    }

    // MARK: Choice

    /// Reads a DataChoice's selector.
    ///
    /// UNVERIFIED against a live node: the reference node's only DataChoice is
    /// the Axis PTZ control stream, which has no archived messages, and its
    /// binary encoding declares no member for the selector at all — only for
    /// the items. One byte is what osh-core's binary writer emits and what this
    /// pass's spec states; if a node is ever seen to disagree, the node wins.
    /// See BINARY_FORMAT.md.
    mutating func readChoiceSelector(at path: FieldPath, itemNames: [String]) throws -> Int {
        let index: Int
        if encoding.member(for: path) != nil {
            index = try readInt(at: path)
        } else {
            index = Int(try readByte(at: path))
        }
        guard itemNames.indices.contains(index) else {
            throw SWEDecodeError.invalidValue(
                "choice selector \(index) is outside 0..<\(itemNames.count)", path)
        }
        return index
    }

    // MARK: Member lookup

    private func dataType(at path: FieldPath) throws -> SWEDataType {
        guard let member = encoding.member(for: path) else {
            throw SWEDecodeError.invalidValue("binary encoding has no member for this path", path)
        }
        guard case .component(let type, _, _, _) = member.kind else {
            throw SWEDecodeError.invalidValue("member is a Block, not a scalar", path)
        }
        return type
    }

    // MARK: Value reading

    /// Reads an integer of `type`'s width, sign-extending the signed forms.
    private mutating func readIntegral(_ type: SWEDataType, at path: FieldPath) throws -> Int {
        guard let width = type.byteWidth else {
            throw SWEDecodeError.invalidValue("\(type) has no fixed width", path)
        }
        let raw = try readUInt(width, at: path)
        switch type {
        case .byte:        return Int(Int8(bitPattern: UInt8(truncatingIfNeeded: raw)))
        case .short:       return Int(Int16(bitPattern: UInt16(truncatingIfNeeded: raw)))
        case .int:         return Int(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))
        case .signedLong:  return Int(Int64(bitPattern: raw))
        case .boolean:     return raw != 0 ? 1 : 0
        default:           return Int(bitPattern: UInt(raw))   // unsigned forms
        }
    }

    /// A 2-byte length followed by that many bytes of text.
    ///
    /// This is java.io.DataOutputStream.writeUTF framing, which the node's
    /// writer uses. The payload is modified UTF-8 rather than standard UTF-8 —
    /// they differ only for NUL and for characters outside the BMP — so
    /// standard decoding is tried first and the modified form is the fallback.
    private mutating func readText(at path: FieldPath) throws -> String {
        let length = Int(try readUInt(2, at: path))
        let bytes = try take(length, at: path)

        if let text = String(bytes: bytes, encoding: .utf8) { return text }
        return Self.decodeModifiedUTF8(bytes)
    }

    private mutating func readByte(at path: FieldPath) throws -> UInt8 {
        try take(1, at: path)[0]
    }

    /// Reads `width` bytes as an unsigned integer in the encoding's byte order.
    private mutating func readUInt(_ width: Int, at path: FieldPath) throws -> UInt64 {
        let bytes = try take(width, at: path)
        var value: UInt64 = 0
        switch encoding.byteOrder {
        case .bigEndian:    for byte in bytes { value = value << 8 | UInt64(byte) }
        case .littleEndian: for byte in bytes.reversed() { value = value << 8 | UInt64(byte) }
        }
        return value
    }

    /// Consumes `count` bytes, or throws. Never returns a short read and never
    /// indexes out of bounds — a malformed message from a node must surface as
    /// a diagnosable error, not a crash in a background stream task.
    private mutating func take(_ count: Int, at path: FieldPath) throws -> [UInt8] {
        guard count >= 0 else {
            throw SWEDecodeError.invalidValue("negative length \(count)", path)
        }
        guard offset + count <= data.count else {
            throw SWEDecodeError.invalidValue(
                "message underrun: needed \(count) bytes, \(data.count - offset) remain", path)
        }
        let start = data.startIndex + offset
        let bytes = [UInt8](data[start ..< start + count])
        offset += count
        return bytes
    }

    // MARK: Modified UTF-8

    /// Java's modified UTF-8: NUL is written as C0 80, and a character outside
    /// the BMP is written as its two surrogates encoded separately (CESU-8).
    /// Anything unrecognised is passed through as Latin-1 rather than dropped,
    /// so a decode never loses the rest of the string.
    private static func decodeModifiedUTF8(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        var index = 0

        func combine(_ high: UInt32, _ low: UInt32) -> UInt32 {
            0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
        }

        while index < bytes.count {
            let byte = bytes[index]
            var value: UInt32
            var width: Int

            switch byte {
            case 0x00...0x7F:
                value = UInt32(byte); width = 1
            case 0xC0...0xDF where index + 1 < bytes.count:
                value = (UInt32(byte & 0x1F) << 6) | UInt32(bytes[index + 1] & 0x3F); width = 2
            case 0xE0...0xEF where index + 2 < bytes.count:
                value = (UInt32(byte & 0x0F) << 12)
                    | (UInt32(bytes[index + 1] & 0x3F) << 6)
                    | UInt32(bytes[index + 2] & 0x3F)
                width = 3
            default:
                value = UInt32(byte); width = 1
            }

            // A high surrogate followed by a low one is one character.
            if (0xD800...0xDBFF).contains(value), index + width + 2 < bytes.count {
                let low = (UInt32(bytes[index + width] & 0x0F) << 12)
                    | (UInt32(bytes[index + width + 1] & 0x3F) << 6)
                    | UInt32(bytes[index + width + 2] & 0x3F)
                if (0xDC00...0xDFFF).contains(low) {
                    value = combine(value, low)
                    width += 3
                }
            }

            scalars.append(Unicode.Scalar(value) ?? Unicode.Scalar(UInt8(byte)))
            index += width
        }

        return String(scalars)
    }
}
