import Foundation

// MARK: - DatastreamDecoder
//
// One datastream's schema, its parser tree, and the two entry points a caller
// actually wants: give me bytes, get observations.
//
// The tree is built once in init. That is the whole point of the architecture —
// a live stream decoding at frame rate must not re-read a schema per message —
// and it is why a schema that cannot produce a tree fails here, at connect
// time, rather than on the first frame.
//
// Sendable and immutable, so one decoder serves a WebSocket task and a paged
// REST fetch concurrently.

final class DatastreamDecoder: Sendable {

    let datastreamId: String
    let schema: SWESchemaDecoder.DatastreamSchema
    let tree: SWEParserTree

    init(datastreamId: String, schema: SWESchemaDecoder.DatastreamSchema) throws {
        self.datastreamId = datastreamId
        self.schema = schema
        self.tree = try SWEParserTree(schema: schema)
    }

    // MARK: Decoding

    /// Decodes swe+json or om+json — the shape is detected from the payload.
    func decode(json data: Data) throws -> [ParsedObservation] {
        var source: any TokenSource = try JSONTokenSource(data: data)
        return try tree.decode(from: &source, datastreamId: datastreamId)
    }

    /// Decodes swe+binary.
    ///
    /// - Throws: `SWEDecodeError.malformedTopLevel` when this datastream has no
    ///   binary encoding. Binary is unreadable without the member table, and
    ///   guessing widths from component types would corrupt silently.
    func decode(binary data: Data) throws -> [ParsedObservation] {
        guard let encoding = schema.recordEncoding else {
            throw SWEDecodeError.malformedTopLevel(
                "datastream \(datastreamId) has no binary recordEncoding")
        }
        var source: any TokenSource = BinaryTokenSource(data: data, encoding: encoding)
        return try tree.decode(from: &source, datastreamId: datastreamId)
    }

    // MARK: Stream shape

    /// True when observations are frame-sized binary rather than scalars.
    var isBinaryBlockStream: Bool { schema.recordEncoding?.blockCompression != nil }

    /// The format to open a live stream with.
    ///
    /// A block stream has no usable JSON form at all — the node substitutes a
    /// placeholder string for the compressed result — so binary is not a
    /// preference there so much as the only option.
    var preferredStreamFormat: String {
        isBinaryBlockStream ? "application/swe+binary" : "application/swe+json"
    }

    /// The codec of this stream's frames, when it carries any.
    var blockCompression: String? { schema.recordEncoding?.blockCompression }
}
