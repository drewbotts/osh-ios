import Foundation

// MARK: - BinaryEncoding (encode side)
//
// Maps a DataRecord field path to its wire type. A `.block` member is what
// marks a datastream as large-binary (video): ObservationPublisher skips those
// modules and SensorCard renders them as a video tile rather than as rows.
//
// This is the type the datastream registration builders write. It is
// deliberately narrower than what a node can express — see
// DecodedBinaryEncoding below for the read side.

enum BinaryFieldType: Sendable {
    case scalar(SWEDataType)
    case block(compression: String) // e.g. "H264", "JPEG"
}

struct BinaryFieldEncoding: Sendable {
    let ref: String           // "/fieldName" path
    let type: BinaryFieldType
}

struct BinaryEncoding: Sendable {
    var byteOrder: String = "bigEndian"
    var byteEncoding: String = "raw"
    var fields: [BinaryFieldEncoding]

    /// The compression code of the first block member, if any — the codec the
    /// frames on this datastream are encoded with.
    var blockCompression: String? {
        for field in fields {
            if case .block(let compression) = field.type { return compression }
        }
        return nil
    }

    /// True when this encoding carries a BinaryBlock member, i.e. observations
    /// are frame-sized binary rather than scalars.
    var hasBinaryBlock: Bool { blockCompression != nil }
}

// MARK: - Byte order

enum ByteOrder: String, Sendable {
    case bigEndian
    case littleEndian

    /// Parses the SWE spelling, defaulting to big-endian.
    ///
    /// Big-endian is both the SWE Common default and what the reference node
    /// emits; a node that omits byteOrder means network order, not host order.
    static func parse(_ raw: String?) -> ByteOrder {
        guard let raw else { return .bigEndian }
        return raw.compare("littleEndian", options: .caseInsensitive) == .orderedSame
            ? .littleEndian : .bigEndian
    }
}

// MARK: - BinaryEncoding (decode side)

/// One member of a node's BinaryEncoding.
///
/// Kept separate from BinaryFieldEncoding because the two describe different
/// things. BinaryFieldEncoding is what this app *asks a node to accept*, so it
/// carries only the two shapes the app writes. BinaryMember is what a node
/// *reports*, including byte lengths, bit-packed widths and block padding that
/// no local sensor produces but a remote datastream may.
struct BinaryMember: Sendable {

    enum Kind: Sendable {
        /// A scalar value at `ref`.
        ///
        /// `byteLength` overrides the dataType's natural width (a text field
        /// with a fixed field width, say). `significantBits` and `bitLength`
        /// describe bit-packed values.
        case component(dataType: SWEDataType,
                       byteLength: Int?,
                       significantBits: Int?,
                       bitLength: Int?)

        /// An opaque run of bytes at `ref` — a compressed frame, typically.
        ///
        /// When a Block's ref names a DataArray, the array is not walked
        /// element by element: the whole array *is* the block. That is the one
        /// signal separating a video datastream from a numeric array one.
        case block(compression: String?,
                   encryption: String?,
                   byteLength: Int?,
                   paddingBytesBefore: Int?,
                   paddingBytesAfter: Int?)
    }

    /// Path to the component this member encodes, always "/"-prefixed.
    ///
    /// For a DataArray the node names the element type once — "/spectrum/value"
    /// rather than one ref per index — so a single member describes every
    /// element of the array.
    let ref: String
    let kind: Kind

    init(ref: String, kind: Kind) {
        self.ref = ref
        self.kind = kind
    }
}

/// A node's BinaryEncoding, decoded.
struct DecodedBinaryEncoding: Sendable {
    let byteOrder: ByteOrder
    let byteEncoding: String   // "raw" / "base64"
    let members: [BinaryMember]

    init(byteOrder: ByteOrder, byteEncoding: String, members: [BinaryMember]) {
        self.byteOrder = byteOrder
        self.byteEncoding = byteEncoding
        self.members = members
    }

    /// The member describing `path`, if the encoding names one.
    ///
    /// Falls back to the path with its index components removed. A node writes
    /// one member per DataArray *element type* — "/spectrum/value" — while the
    /// decoder reads element 3 at "/spectrum/3/value", so an exact match alone
    /// would find nothing for any array element.
    func member(for path: FieldPath) -> BinaryMember? {
        let key = path.description
        if let exact = members.first(where: { $0.ref == key }) { return exact }

        let unindexed = path.components.filter { Int($0) == nil }
        guard unindexed.count != path.components.count else { return nil }
        let fallback = FieldPath(components: unindexed).description
        return members.first { $0.ref == fallback }
    }

    /// The compression code of the first Block member, if any.
    var blockCompression: String? {
        for member in members {
            if case .block(let compression, _, _, _, _) = member.kind {
                return compression
            }
        }
        return nil
    }

    /// True when a Block member sits at exactly `path` — the test for "this
    /// DataArray arrives as one opaque frame".
    func hasBlock(at path: FieldPath) -> Bool {
        guard let member = member(for: path) else { return false }
        if case .block = member.kind { return true }
        return false
    }
}
