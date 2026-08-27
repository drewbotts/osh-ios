import Foundation

// MARK: - BinaryTokenSource
//
// Reads application/swe+binary. The exact inverse of
// ConnectedSystemsClient.buildBinaryObsBody, verified against frames captured
// from a live node:
//
//   scalar   fixed-width, byte order from the encoding (big-endian in practice)
//   text     2-byte big-endian length, then that many UTF-8 bytes
//   boolean  one byte, zero is false
//   block    4-byte big-endian length, then that many opaque bytes
//
// Binary is positional: nothing in the stream names a field, so a value is
// whatever the schema says comes next. That makes every read destructive and
// makes a wrong width silent corruption rather than an error — which is why the
// member table is consulted for each path instead of guessing from the
// component type.

struct BinaryTokenSource: TokenSource {

    private let data: Data
    private let encoding: DecodedBinaryEncoding
    private var offset: Int

    /// Byte offset at which the current record began, so a caller can measure
    /// what one record consumed.
    private(set) var recordStart: Int

    init(data: Data, encoding: DecodedBinaryEncoding) {
        self.data = data
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
        let type = try dataType(at: path)
        switch type {
        case .double:      return Double(bitPattern: try readUInt(8, at: path))
        case .float:       return Double(Float(bitPattern: UInt32(try readUInt(4, at: path))))
        case .boolean:     return try readBool(at: path) ? 1 : 0
        case .string, .utf8String:
            // A node may declare a numeric component as text. Reading the
            // bytes and converting is better than refusing the whole record.
            guard let value = Double(try readString(at: path)) else {
                throw TokenSourceError.typeMismatch(expected: "a number", at: path)
            }
            return value
        default:           return Double(try readIntegral(type, at: path))
        }
    }

    mutating func readInt(at path: FieldPath) throws -> Int {
        let type = try dataType(at: path)
        switch type {
        case .double:  return Int(Double(bitPattern: try readUInt(8, at: path)))
        case .float:   return Int(Float(bitPattern: UInt32(try readUInt(4, at: path))))
        case .boolean: return try readBool(at: path) ? 1 : 0
        case .string, .utf8String:
            guard let value = Int(try readString(at: path)) else {
                throw TokenSourceError.typeMismatch(expected: "an integer", at: path)
            }
            return value
        default:       return try readIntegral(type, at: path)
        }
    }

    mutating func readBool(at path: FieldPath) throws -> Bool {
        let type = try dataType(at: path)
        guard type == .boolean else { return try readIntegral(type, at: path) != 0 }
        return try readByte(at: path) != 0
    }

    mutating func readString(at path: FieldPath) throws -> String {
        _ = try dataType(at: path)
        let length = Int(try readUInt(2, at: path))
        let bytes = try take(length, at: path)
        // A node is free to send bytes that are not valid UTF-8; replacing the
        // bad scalars keeps the rest of the record readable.
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func readTime(at path: FieldPath) throws -> Date {
        Date(timeIntervalSince1970: try readDouble(at: path))
    }

    // MARK: Blocks

    mutating func readBlock(at path: FieldPath) throws -> (Data, compression: String?) {
        guard let member = encoding.member(for: path),
              case .block(let compression, _, let declaredLength,
                          let padBefore, let padAfter) = member.kind else {
            throw TokenSourceError.noEncodingMember(path)
        }

        if let padBefore { _ = try take(padBefore, at: path) }

        // A Block with no declared byteLength is length-prefixed on the wire,
        // which is what every video datastream on the reference node does.
        let length = try declaredLength ?? Int(readUInt(4, at: path))
        let payload = try take(length, at: path)

        if let padAfter { _ = try take(padAfter, at: path) }

        return (Data(payload), compression: compression)
    }

    // MARK: Choice

    mutating func readChoiceSelector(at path: FieldPath, itemNames: [String]) throws -> Int {
        // The selector's own width comes from its member when the encoding
        // declares one; SWE Common's default for a choice tag is a 4-byte int.
        let index: Int
        if encoding.member(for: path) != nil {
            index = try readInt(at: path)
        } else {
            index = Int(Int32(bitPattern: UInt32(try readUInt(4, at: path))))
        }
        guard itemNames.indices.contains(index) else {
            throw TokenSourceError.unknownChoice("index \(index)", at: path)
        }
        return index
    }

    // MARK: Byte reading

    private func dataType(at path: FieldPath) throws -> SWEDataType {
        guard let member = encoding.member(for: path) else {
            throw TokenSourceError.noEncodingMember(path)
        }
        guard case .component(let type, _, _, _) = member.kind else {
            throw TokenSourceError.typeMismatch(expected: "a scalar component", at: path)
        }
        return type
    }

    /// Reads an integer of `type`'s width, sign-extending the signed types.
    private mutating func readIntegral(_ type: SWEDataType, at path: FieldPath) throws -> Int {
        guard let width = type.byteWidth else {
            throw TokenSourceError.typeMismatch(expected: "a fixed-width number", at: path)
        }
        let raw = try readUInt(width, at: path)
        switch type {
        case .byte:       return Int(Int8(bitPattern: UInt8(truncatingIfNeeded: raw)))
        case .short:      return Int(Int16(bitPattern: UInt16(truncatingIfNeeded: raw)))
        case .int:        return Int(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))
        case .signedLong: return Int(Int64(bitPattern: raw))
        default:          return Int(bitPattern: UInt(raw))   // unsigned forms
        }
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

    /// Consumes `count` bytes, or throws rather than returning a short read —
    /// a truncated value would decode to a plausible wrong number.
    private mutating func take(_ count: Int, at path: FieldPath) throws -> [UInt8] {
        guard count >= 0, offset + count <= data.count else {
            throw TokenSourceError.truncated(at: path,
                                             needed: count,
                                             available: data.count - offset)
        }
        let start = data.startIndex + offset
        let bytes = [UInt8](data[start ..< start + count])
        offset += count
        return bytes
    }
}
