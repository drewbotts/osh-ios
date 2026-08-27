import Foundation

// MARK: - SWEParserTree
//
// A schema walked once into a tree of reader nodes, then fed a TokenSource per
// message. This is the osh-js parser architecture: the expensive work — reading
// the schema, resolving references, deciding whether a DataArray is a numeric
// array or a video frame — happens on build, and each message afterwards is a
// walk over a prepared structure.
//
// The tree is Sendable and immutable once built, so one tree can decode a live
// WebSocket stream on a background task while the same instance serves a
// paged REST fetch.

struct SWEParserTree: Sendable {

    // MARK: Node

    /// How a DataArray learns its length.
    enum SizeSource: Sendable, Equatable {
        /// The schema inlined a Count with a value.
        case fixed(Int)
        /// The elementCount referred to a Count field elsewhere in the record,
        /// whose value arrives with each observation.
        case path(FieldPath)
        /// Neither: the payload's own shape decides — a JSON array's length, or
        /// a length read from the stream.
        case payload
    }

    enum ScalarKind: Sendable, Equatable {
        case double, int, bool, text, time, block
    }

    indirect enum ParserNode: Sendable {
        case record(name: String, children: [ParserNode])
        case vector(name: String, children: [ParserNode])
        case array(name: String, path: FieldPath, sizeSource: SizeSource, element: ParserNode)
        /// A DataArray whose bytes arrive as one opaque block — a video frame.
        case blockArray(name: String, path: FieldPath)
        case choice(name: String, path: FieldPath, itemNames: [String], items: [ParserNode])
        case scalar(path: FieldPath, kind: ScalarKind)
    }

    // MARK: Stored

    let root: ParserNode
    /// Path of the Time leaf that supplies phenomenonTime, resolved once at
    /// build time rather than re-derived per message.
    let phenomenonTimePath: FieldPath?

    // MARK: Build

    /// Builds a parser tree from a decoded schema.
    ///
    /// - Throws: `SWEDecodeError.unresolvedReference` when an href or an
    ///   elementCount ref names an id the schema never declares. Failing here
    ///   is deliberate: a dangling reference means every later field in the
    ///   record would be read at the wrong offset.
    init(schema: SWESchemaDecoder.DatastreamSchema) throws {
        var timeCandidates: [(path: FieldPath, isPhenomenon: Bool)] = []

        self.root = try Self.node(for: schema.recordSchema,
                                  name: schema.recordSchema.name,
                                  at: FieldPath(components: []),
                                  schema: schema,
                                  timeCandidates: &timeCandidates)

        // PhenomenonTime/SamplingTime by definition first, then the first Time
        // leaf of any kind. A record with no Time at all leaves this nil and
        // the decoder falls back to the envelope time or to now().
        self.phenomenonTimePath = timeCandidates.first(where: \.isPhenomenon)?.path
            ?? timeCandidates.first?.path
    }

    private static func node(for component: DataComponent,
                             name: String,
                             at path: FieldPath,
                             schema: SWESchemaDecoder.DatastreamSchema,
                             timeCandidates: inout [(path: FieldPath, isPhenomenon: Bool)]) throws -> ParserNode {

        switch component {

        case let href as SWEHref:
            // Resolving an href needs the component the id points at, and the
            // id index stores paths, not components — so walk to it.
            guard let target = schema.idIndex[href.ref],
                  let resolved = Self.component(at: target, in: schema.recordSchema) else {
                throw SWEDecodeError.unresolvedReference(href.ref)
            }
            return try node(for: resolved, name: name, at: path,
                            schema: schema, timeCandidates: &timeCandidates)

        case let record as DataRecord:
            return .record(name: name, children: try record.fields.map { field in
                try node(for: field.component, name: field.name,
                         at: path.appending(field.name),
                         schema: schema, timeCandidates: &timeCandidates)
            })

        case let vector as SWEVector:
            return .vector(name: name, children: try vector.coordinates.map { coordinate in
                try node(for: coordinate.component, name: coordinate.name,
                         at: path.appending(coordinate.name),
                         schema: schema, timeCandidates: &timeCandidates)
            })

        case let array as SWEDataArray:
            return try arrayNode(name: name, at: path,
                                 elementCount: array.elementCount,
                                 elementTypeName: array.elementTypeName,
                                 elementType: array.elementType,
                                 schema: schema, timeCandidates: &timeCandidates)

        case let matrix as SWEMatrix:
            return try arrayNode(name: name, at: path,
                                 elementCount: matrix.elementCount,
                                 elementTypeName: matrix.elementTypeName,
                                 elementType: matrix.elementType,
                                 schema: schema, timeCandidates: &timeCandidates)

        case let choice as SWEDataChoice:
            var items: [ParserNode] = []
            for item in choice.items {
                items.append(try node(for: item.component, name: item.name,
                                      at: path.appending(item.name),
                                      schema: schema, timeCandidates: &timeCandidates))
            }
            return .choice(name: name, path: path,
                           itemNames: choice.items.map(\.name), items: items)

        case let time as TimeComponent:
            timeCandidates.append((path, time.isPhenomenonTime))
            return .scalar(path: path, kind: .time)

        case is SWECount:
            return .scalar(path: path, kind: .int)

        case is SWEBoolean:
            return .scalar(path: path, kind: .bool)

        case is SWEText, is SWECategory:
            return .scalar(path: path, kind: .text)

        default:
            // Quantity, ranges, geometry and anything else numeric.
            return .scalar(path: path, kind: .double)
        }
    }

    /// A DataArray is either walked element by element or read as one block.
    ///
    /// The distinction is not in the schema — a video's img array and a
    /// spectrum's frequency array are both "DataArray of numbers". It is the
    /// binary encoding putting a Block member at the array's own path that says
    /// the whole array arrives compressed. Walking a 1512 × 2688 × 3 pixel
    /// structure element-wise would be both wrong and unbounded.
    private static func arrayNode(name: String,
                                  at path: FieldPath,
                                  elementCount: SWECount,
                                  elementTypeName: String,
                                  elementType: DataComponent,
                                  schema: SWESchemaDecoder.DatastreamSchema,
                                  timeCandidates: inout [(path: FieldPath, isPhenomenon: Bool)]) throws -> ParserNode {

        if schema.recordEncoding?.hasBlock(at: path) == true {
            return .blockArray(name: name, path: path)
        }

        let sizeSource: SizeSource
        if let value = elementCount.value {
            sizeSource = .fixed(value)
        } else if let ref = elementCount.ref {
            guard let target = schema.idIndex[ref] else {
                throw SWEDecodeError.unresolvedReference(ref)
            }
            sizeSource = .path(target)
        } else {
            sizeSource = .payload
        }

        // The element is described once, at "<array>/<elementTypeName>" — the
        // same path the binary encoding's single member uses. Per-element paths
        // are built from it at decode time by inserting the index.
        var elementTimes: [(path: FieldPath, isPhenomenon: Bool)] = []
        let element = try node(for: elementType,
                               name: elementTypeName,
                               at: path.appending(elementTypeName),
                               schema: schema,
                               timeCandidates: &elementTimes)

        return .array(name: name, path: path, sizeSource: sizeSource, element: element)
    }

    /// Walks the record to the component sitting at `path`.
    private static func component(at path: FieldPath, in record: DataRecord) -> DataComponent? {
        var current: DataComponent = record
        for name in path.components {
            switch current {
            case let record as DataRecord:
                guard let field = record.fields.first(where: { $0.name == name }) else { return nil }
                current = field.component
            case let vector as SWEVector:
                guard let coordinate = vector.coordinates.first(where: { $0.name == name }) else { return nil }
                current = coordinate.component
            case let choice as SWEDataChoice:
                guard let item = choice.items.first(where: { $0.name == name }) else { return nil }
                current = item.component
            case let array as SWEDataArray:
                guard array.elementTypeName == name else { return nil }
                current = array.elementType
            case let matrix as SWEMatrix:
                guard matrix.elementTypeName == name else { return nil }
                current = matrix.elementType
            default:
                return nil
            }
        }
        return current
    }

    // MARK: Decode

    /// Decodes every record the source holds.
    func decode(from source: inout any TokenSource,
                datastreamId: String) throws -> [ParsedObservation] {
        var observations: [ParsedObservation] = []
        while source.hasMoreRecords {
            source.beginRecord()
            observations.append(try decodeRecord(from: &source, datastreamId: datastreamId))
        }
        return observations
    }

    /// Decodes exactly one record — the shape a WebSocket message delivers.
    func decodeRecord(from source: inout any TokenSource,
                      datastreamId: String) throws -> ParsedObservation {
        var values: [FieldPath: FieldValue] = [:]
        var paths: [FieldPath] = []

        try walk(root, prefix: nil, source: &source, values: &values, paths: &paths)

        // Schema order first, envelope time second, now() last. The last case
        // is not a fiction to be avoided: a record genuinely without a time
        // still has to land somewhere on a timeline to be displayed at all.
        let time: Date
        if let path = phenomenonTimePath, case .time(let date)? = values[path] {
            time = date
        } else if let external = source.externalTime {
            time = external
        } else {
            time = Date()
        }

        return ParsedObservation(datastreamId: datastreamId,
                                 phenomenonTime: time,
                                 values: values,
                                 orderedPaths: paths)
    }

    /// Walks one node, reading tokens in schema order.
    ///
    /// `prefix` rewrites the path a node reads at. It is non-nil only inside a
    /// DataArray, where the schema describes one element but the payload has
    /// many: element 3's fields are read at "/arr/3/…" while the tree still
    /// holds "/arr/<elementName>/…".
    private func walk(_ node: ParserNode,
                      prefix: (from: FieldPath, to: FieldPath)?,
                      source: inout any TokenSource,
                      values: inout [FieldPath: FieldValue],
                      paths: inout [FieldPath]) throws {

        switch node {

        case .record(_, let children), .vector(_, let children):
            for child in children {
                try walk(child, prefix: prefix, source: &source, values: &values, paths: &paths)
            }

        case .scalar(let path, let kind):
            let readPath = rewrite(path, with: prefix)
            let value: FieldValue
            switch kind {
            case .double: value = .double(try source.readDouble(at: readPath))
            case .int:    value = .int(try source.readInt(at: readPath))
            case .bool:   value = .bool(try source.readBool(at: readPath))
            case .text:   value = .text(try source.readString(at: readPath))
            case .time:   value = .time(try time(at: readPath, source: &source))
            case .block:
                let (data, compression) = try source.readBlock(at: readPath)
                value = .block(data, compression: compression)
            }
            record(value, at: readPath, values: &values, paths: &paths)

        case .blockArray(_, let path):
            let readPath = rewrite(path, with: prefix)
            let (data, compression) = try source.readBlock(at: readPath)
            record(.block(data, compression: compression),
                   at: readPath, values: &values, paths: &paths)

        case .array(_, let path, let sizeSource, let element):
            let arrayPath = rewrite(path, with: prefix)
            let count = try size(sizeSource, arrayPath: arrayPath, source: &source, values: values)
            for index in 0 ..< count {
                // Element paths are the array's path plus the index; the
                // element subtree's own paths are rebased onto it.
                try walk(element,
                         prefix: (from: path, to: arrayPath.appending("\(index)")),
                         source: &source, values: &values, paths: &paths)
            }

        case .choice(_, let path, let itemNames, let items):
            let choicePath = rewrite(path, with: prefix)
            let selected = try source.readChoiceSelector(at: choicePath, itemNames: itemNames)
            // The selection is itself an observed value — without it a consumer
            // would have to infer which alternative arrived from which paths
            // happen to be populated.
            record(.text(itemNames[selected]), at: choicePath, values: &values, paths: &paths)
            try walk(items[selected], prefix: prefix,
                     source: &source, values: &values, paths: &paths)
        }
    }

    /// Reads a Time leaf, falling back to the envelope.
    ///
    /// om+json omits the record's own Time field from `result` for some of the
    /// node's drivers — gps and spectrum send only `location`/`channel`… and
    /// leave the instant to the envelope's phenomenonTime — while others repeat
    /// it inside the result. A missing Time is therefore ordinary rather than
    /// malformed, and the envelope is the value the node meant.
    ///
    /// Only Time behaves this way. Any other missing leaf still throws: a
    /// silently absent measurement would be indistinguishable from a real zero.
    private func time(at path: FieldPath, source: inout any TokenSource) throws -> Date {
        do {
            return try source.readTime(at: path)
        } catch let error as TokenSourceError {
            guard case .missingValue = error, let external = source.externalTime else {
                throw error
            }
            return external
        }
    }

    /// Leaf paths as a binary encoding writes them — array elements addressed
    /// by their element type's name rather than by index, because that is how a
    /// node writes the single member describing them.
    var encodingLeafPaths: [FieldPath] {
        var paths: [FieldPath] = []
        Self.collectEncodingPaths(root, into: &paths)
        return paths
    }

    private static func collectEncodingPaths(_ node: ParserNode, into paths: inout [FieldPath]) {
        switch node {
        case .record(_, let children), .vector(_, let children):
            for child in children { collectEncodingPaths(child, into: &paths) }
        case .choice(_, _, _, let items):
            for item in items { collectEncodingPaths(item, into: &paths) }
        case .array(_, _, _, let element):
            collectEncodingPaths(element, into: &paths)
        case .blockArray(_, let path):
            paths.append(path)
        case .scalar(let path, _):
            paths.append(path)
        }
    }

    /// How many elements this array carries.
    private func size(_ sizeSource: SizeSource,
                      arrayPath: FieldPath,
                      source: inout any TokenSource,
                      values: [FieldPath: FieldValue]) throws -> Int {
        switch sizeSource {
        case .fixed(let count):
            return count

        case .path(let countPath):
            // The Count field was read earlier in this same record — schema
            // order guarantees it, since a node writes the count before the
            // array it sizes.
            guard case .int(let count)? = values[countPath] else {
                throw SWEDecodeError.unresolvedReference(countPath.description)
            }
            return count

        case .payload:
            if let json = source as? JSONTokenSource, let count = json.arrayCount(at: arrayPath) {
                return count
            }
            throw SWEDecodeError.invalidValue("array size is not determinable", arrayPath)
        }
    }

    /// Rebases a path built at schema-build time onto the path being read.
    private func rewrite(_ path: FieldPath, with prefix: (from: FieldPath, to: FieldPath)?) -> FieldPath {
        guard let prefix else { return path }
        let from = prefix.from.components
        guard path.components.count >= from.count,
              Array(path.components.prefix(from.count)) == from else { return path }
        // The element type's name is KEPT: "/spectrum/3/value" rather than
        // "/spectrum/3". It is what the binary encoding's single element member
        // is keyed by, and in JSON it is harmlessly absorbed when the element
        // is a bare number.
        let tail = path.components.dropFirst(from.count)
        return FieldPath(components: prefix.to.components + tail)
    }

    private func record(_ value: FieldValue,
                        at path: FieldPath,
                        values: inout [FieldPath: FieldValue],
                        paths: inout [FieldPath]) {
        if values.updateValue(value, forKey: path) == nil {
            paths.append(path)
        }
    }
}
