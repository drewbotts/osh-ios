import Foundation

// MARK: - SWESchemaDecoder
//
// Turns a Connected Systems schema document into a DataComponent tree.
//
// JSONSerialization rather than Codable, because SWE JSON is polymorphic on a
// "type" string and its containers are heterogeneous: a DataRecord's "fields"
// array holds Quantities next to Vectors next to DataArrays, and a Codable
// decoder would need a hand-written init(from:) per container anyway. Reading
// the object graph directly keeps the discrimination in one place.
//
// Everything here is decode-only. The encoder's builders construct components
// directly and never come through this file.

enum SWESchemaDecoder {

    // MARK: Result

    struct DatastreamSchema: Sendable {
        /// The obsFormat this schema describes, e.g. "application/swe+json".
        let obsFormat: String
        let recordSchema: DataRecord
        /// Present only for application/swe+binary. A text or JSON encoding
        /// leaves this nil — those formats need no member table.
        let recordEncoding: DecodedBinaryEncoding?
        /// Component id → the path that component sits at, for href resolution.
        let idIndex: [String: FieldPath]
    }

    // MARK: Top level

    /// Decodes a `/datastreams/{id}/schema` document.
    ///
    /// Three shapes are accepted, all of which the reference node serves:
    ///   • the datastream schema resource — obsFormat + recordSchema (+ recordEncoding)
    ///   • a bare DataRecord
    ///   • a control stream's schema resource, keyed "paramsSchema"
    ///
    /// The last is not an observation schema and this pass implements no
    /// command support, but decoding it costs nothing and is the only place the
    /// reference node exposes a DataChoice at all.
    static func decode(_ data: Data) throws -> DatastreamSchema {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SWEDecodeError.malformedTopLevel("top-level value is not a JSON object")
            }
            root = object
        } catch let error as SWEDecodeError {
            throw error
        } catch {
            throw SWEDecodeError.malformedTopLevel("not valid JSON: \(error.localizedDescription)")
        }

        var idIndex: [String: FieldPath] = [:]
        let rootPath = FieldPath(components: [])

        // A bare component document — the "type" is at the top level.
        if root["type"] != nil {
            let component = try decodeComponent(root, at: rootPath, idIndex: &idIndex)
            return DatastreamSchema(obsFormat: string(root["obsFormat"]) ?? "",
                                    recordSchema: asRecord(component,
                                                           name: string(root["name"])),
                                    recordEncoding: nil,
                                    idIndex: idIndex)
        }

        guard let schemaObject = (root["recordSchema"] ?? root["paramsSchema"]) as? [String: Any] else {
            throw SWEDecodeError.malformedTopLevel(
                "no \"recordSchema\", \"paramsSchema\" or \"type\" key")
        }

        let component = try decodeComponent(schemaObject, at: rootPath, idIndex: &idIndex)
        let record = asRecord(component, name: string(schemaObject["name"]))

        var encoding: DecodedBinaryEncoding?
        if let encodingObject = root["recordEncoding"] as? [String: Any] {
            encoding = try decodeEncoding(encodingObject)
        }

        return DatastreamSchema(obsFormat: string(root["obsFormat"]) ?? "",
                                recordSchema: record,
                                recordEncoding: encoding,
                                idIndex: idIndex)
    }

    /// Coerces a decoded top-level component to the DataRecord the rest of the
    /// pipeline expects.
    ///
    /// A node may put something other than a DataRecord at the root — a control
    /// stream's params are a bare DataChoice. Rather than reject it, wrap it in
    /// a single-field record, which is structurally what a record containing
    /// that one component would have been.
    ///
    /// The wrapper's field takes the component's own "name" so that paths match
    /// what a payload actually carries: the PTZ choice arrives keyed
    /// "ptzControl", and naming the field anything else would put every value
    /// at a path no lookup ever asks for.
    private static func asRecord(_ component: DataComponent, name: String?) -> DataRecord {
        if let record = component as? DataRecord { return record }
        let fieldName = name ?? component.label ?? "record"
        return DataRecord(definition: component.definition,
                          label: component.label,
                          name: fieldName,
                          fields: [DataField(name: fieldName, component: component)],
                          description: component.description,
                          id: component.id)
    }

    // MARK: Components

    /// Decodes one component and everything below it.
    ///
    /// `path` is where this component sits in the record; it is threaded
    /// through so that ids land in the index against real paths and so that an
    /// error names the failing field rather than just its type.
    static func decodeComponent(_ json: [String: Any],
                                at path: FieldPath,
                                idIndex: inout [String: FieldPath]) throws -> DataComponent {

        // A bare {"href": "#id"} with no "type" is a reference to a component
        // defined elsewhere. It cannot be resolved yet — the target may not
        // have been read — so it is recorded and resolved at tree-build time.
        guard let type = string(json["type"]) else {
            if let href = string(json["href"]) {
                return SWEHref(ref: href)
            }
            throw SWEDecodeError.missingKey("type", path)
        }

        let id = string(json["id"])
        if let id { idIndex[id] = path }

        let definition  = string(json["definition"])
        let label       = string(json["label"])
        let description = string(json["description"])
        let optional    = bool(json["optional"]) ?? false
        let updatable   = bool(json["updatable"]) ?? false
        let refFrame    = string(json["referenceFrame"])
        let localFrame  = string(json["localFrame"])

        switch type {

        case "DataRecord":
            return DataRecord(definition: definition,
                              label: label,
                              name: string(json["name"]) ?? path.lastComponent,
                              fields: try decodeFields(json,
                                                       keys: ["fields", "field"],
                                                       at: path,
                                                       idIndex: &idIndex),
                              description: description,
                              id: id,
                              optional: optional,
                              updatable: updatable)

        case "Vector":
            return SWEVector(definition: definition,
                             label: label,
                             description: description,
                             refFrame: refFrame,
                             localFrame: localFrame,
                             coordinates: try decodeFields(json,
                                                           keys: ["coordinates", "coordinate"],
                                                           at: path,
                                                           idIndex: &idIndex),
                             id: id,
                             optional: optional,
                             updatable: updatable)

        case "DataArray", "Matrix":
            let (count, elementName, element) =
                try decodeArrayParts(json, at: path, idIndex: &idIndex)
            if type == "Matrix" {
                return SWEMatrix(definition: definition,
                                 label: label,
                                 elementCount: count,
                                 elementTypeName: elementName,
                                 elementType: element,
                                 refFrame: refFrame,
                                 localFrame: localFrame,
                                 description: description,
                                 id: id,
                                 optional: optional,
                                 updatable: updatable)
            }
            return SWEDataArray(definition: definition,
                                label: label,
                                elementCount: count,
                                elementTypeName: elementName,
                                elementType: element,
                                description: description,
                                id: id,
                                optional: optional,
                                updatable: updatable)

        case "DataChoice":
            var choiceValue: SWECategory?
            if let raw = json["choiceValue"] as? [String: Any] {
                let decoded = try decodeComponent(raw,
                                                  at: path.appending("choiceValue"),
                                                  idIndex: &idIndex)
                choiceValue = decoded as? SWECategory
            }
            return SWEDataChoice(definition: definition,
                                 label: label,
                                 description: description,
                                 choiceValue: choiceValue,
                                 items: try decodeFields(json,
                                                         keys: ["items", "item"],
                                                         at: path,
                                                         idIndex: &idIndex),
                                 id: id,
                                 optional: optional,
                                 updatable: updatable)

        case "Quantity":
            let (code, href) = uom(json)
            return Quantity(definition: definition,
                            label: label,
                            description: description,
                            uom: code ?? "",
                            dataType: dataType(json) ?? .double,
                            axisId: string(json["axisID"]),
                            refFrame: refFrame,
                            uomHref: href,
                            constraint: numericConstraint(json),
                            nilValues: nilValues(json),
                            id: id,
                            optional: optional,
                            updatable: updatable)

        case "Count":
            return SWECount(definition: definition,
                            label: label,
                            axisID: string(json["axisID"]),
                            value: int(json["value"]),
                            description: description,
                            ref: nil,
                            constraint: numericConstraint(json),
                            nilValues: nilValues(json),
                            id: id,
                            optional: optional,
                            updatable: updatable)

        case "Boolean":
            return SWEBoolean(definition: definition,
                              label: label,
                              description: description,
                              id: id,
                              optional: optional,
                              updatable: updatable)

        case "Text":
            return SWEText(definition: definition,
                           label: label,
                           description: description,
                           constraint: tokenConstraint(json),
                           nilValues: nilValues(json),
                           id: id,
                           optional: optional,
                           updatable: updatable)

        case "Category":
            return SWECategory(definition: definition,
                               label: label,
                               description: description,
                               codeSpace: codeSpace(json),
                               constraint: tokenConstraint(json),
                               nilValues: nilValues(json),
                               id: id,
                               optional: optional,
                               updatable: updatable)

        case "Time":
            let (_, href) = uom(json)
            return SWETime(definition: definition,
                           label: label,
                           description: description,
                           refFrame: refFrame,
                           uomHref: href,
                           localFrame: localFrame,
                           constraint: numericConstraint(json),
                           nilValues: nilValues(json),
                           id: id,
                           optional: optional,
                           updatable: updatable)

        case "QuantityRange":
            let (code, href) = uom(json)
            return QuantityRange(definition: definition,
                                 label: label,
                                 description: description,
                                 uom: code ?? "",
                                 dataType: dataType(json) ?? .double,
                                 axisId: string(json["axisID"]),
                                 refFrame: refFrame,
                                 uomHref: href,
                                 constraint: numericConstraint(json),
                                 nilValues: nilValues(json),
                                 id: id,
                                 optional: optional,
                                 updatable: updatable)

        case "CountRange":
            return CountRange(definition: definition,
                              label: label,
                              description: description,
                              constraint: numericConstraint(json),
                              nilValues: nilValues(json),
                              id: id,
                              optional: optional,
                              updatable: updatable)

        case "CategoryRange":
            return CategoryRange(definition: definition,
                                 label: label,
                                 description: description,
                                 codeSpace: codeSpace(json),
                                 constraint: tokenConstraint(json),
                                 nilValues: nilValues(json),
                                 id: id,
                                 optional: optional,
                                 updatable: updatable)

        case "TimeRange":
            let (_, href) = uom(json)
            return TimeRange(definition: definition,
                             label: label,
                             description: description,
                             refFrame: refFrame,
                             uomHref: href,
                             localFrame: localFrame,
                             constraint: numericConstraint(json),
                             nilValues: nilValues(json),
                             id: id,
                             optional: optional,
                             updatable: updatable)

        case "Geometry":
            return SWEGeometry(definition: definition,
                               label: label,
                               srs: string(json["srs"]) ?? string(json["referenceFrame"]),
                               description: description,
                               id: id,
                               optional: optional,
                               updatable: updatable)

        default:
            throw SWEDecodeError.unsupportedComponent(type, path)
        }
    }

    // MARK: Containers

    /// Decodes a named-child array — a record's fields, a vector's coordinates
    /// or a choice's items. The singular key is accepted alongside the plural
    /// because SWE JSON writers disagree about which one is canonical.
    private static func decodeFields(_ json: [String: Any],
                                     keys: [String],
                                     at path: FieldPath,
                                     idIndex: inout [String: FieldPath]) throws -> [DataField] {
        guard let raw = keys.lazy.compactMap({ json[$0] as? [Any] }).first else {
            throw SWEDecodeError.missingKey(keys[0], path)
        }

        var fields: [DataField] = []
        fields.reserveCapacity(raw.count)
        for (index, entry) in raw.enumerated() {
            guard let object = entry as? [String: Any] else {
                throw SWEDecodeError.invalidValue("\(keys[0])[\(index)] is not an object", path)
            }
            guard let name = string(object["name"]) else {
                throw SWEDecodeError.missingKey("name", path.appending("[\(index)]"))
            }
            let childPath = path.appending(name)
            fields.append(DataField(name: name,
                                    component: try decodeComponent(object,
                                                                   at: childPath,
                                                                   idIndex: &idIndex)))
        }
        return fields
    }

    /// Decodes a DataArray's or Matrix's size and element type.
    ///
    /// The element type sits at `<arrayPath>/<elementTypeName>`, which is the
    /// same path a binary encoding uses to describe it — a node writes one
    /// member for the element type, not one per index.
    private static func decodeArrayParts(_ json: [String: Any],
                                         at path: FieldPath,
                                         idIndex: inout [String: FieldPath])
                                         throws -> (SWECount, String, DataComponent) {

        guard let elementTypeObject = json["elementType"] as? [String: Any] else {
            throw SWEDecodeError.missingKey("elementType", path)
        }
        // The element type's name is what the binary encoding refs go through,
        // so falling back to the array's own name would silently break the
        // member lookup. "elementType" is a last resort, not a normal path.
        let elementName = string(elementTypeObject["name"]) ?? "elementType"
        let element = try decodeComponent(elementTypeObject,
                                          at: path.appending(elementName),
                                          idIndex: &idIndex)

        return (try decodeElementCount(json["elementCount"], at: path, idIndex: &idIndex),
                elementName,
                element)
    }

    /// An elementCount is an inline Count with a value, a `{"href": "#id"}`
    /// pointing at a Count field elsewhere in the record, or a bare id string.
    private static func decodeElementCount(_ raw: Any?,
                                           at path: FieldPath,
                                           idIndex: inout [String: FieldPath])
                                           throws -> SWECount {
        switch raw {
        case let object as [String: Any]:
            if object["type"] == nil, let href = string(object["href"]) {
                return SWECount(ref: stripFragment(href))
            }
            let component = try decodeComponent(object,
                                                at: path.appending("elementCount"),
                                                idIndex: &idIndex)
            guard let count = component as? SWECount else {
                throw SWEDecodeError.invalidValue("elementCount is not a Count", path)
            }
            return count

        case let href as String:
            return SWECount(ref: stripFragment(href))

        case nil:
            // A variable-size array with no declared size at all: the count
            // arrives with the data (a JSON array's own length, or a length
            // prefix in binary). Left unresolved rather than defaulted to zero.
            return SWECount()

        default:
            throw SWEDecodeError.invalidValue("elementCount has an unusable type", path)
        }
    }

    // MARK: Binary encoding

    /// Decodes a recordEncoding object.
    ///
    /// Returns nil for TextEncoding and JSONEncoding: those formats carry no
    /// member table, and the token source reads them structurally instead.
    static func decodeEncoding(_ json: [String: Any]) throws -> DecodedBinaryEncoding? {
        let type = string(json["type"]) ?? "BinaryEncoding"
        guard type == "BinaryEncoding" else {
            Log.client.debug("Ignoring \(type, privacy: .public) recordEncoding — no member table to decode")
            return nil
        }

        guard let raw = ["members", "member"].lazy.compactMap({ json[$0] as? [Any] }).first else {
            throw SWEDecodeError.missingKey("members", FieldPath(components: []))
        }

        var members: [BinaryMember] = []
        members.reserveCapacity(raw.count)

        for (index, entry) in raw.enumerated() {
            let path = FieldPath(components: ["recordEncoding", "members", "\(index)"])
            guard let object = entry as? [String: Any] else {
                throw SWEDecodeError.invalidValue("member[\(index)] is not an object", path)
            }
            guard let ref = string(object["ref"]) else {
                throw SWEDecodeError.missingKey("ref", path)
            }

            let memberType = string(object["type"]) ?? "Component"
            let kind: BinaryMember.Kind

            switch memberType {
            case "Block":
                kind = .block(compression: string(object["compression"]),
                              encryption: string(object["encryption"]),
                              byteLength: int(object["byteLength"]),
                              paddingBytesBefore: int(object["paddingBytes-before"])
                                  ?? int(object["paddingBytesBefore"]),
                              paddingBytesAfter: int(object["paddingBytes-after"])
                                  ?? int(object["paddingBytesAfter"]))

            case "Component":
                guard let rawType = string(object["dataType"]) else {
                    throw SWEDecodeError.missingKey("dataType", path)
                }
                guard let resolved = SWEDataType.from(uriSuffix: rawType) else {
                    throw SWEDecodeError.invalidValue("unknown dataType \"\(rawType)\"", path)
                }
                kind = .component(dataType: resolved,
                                  byteLength: int(object["byteLength"]),
                                  significantBits: int(object["significantBits"]),
                                  bitLength: int(object["bitLength"]))

            default:
                throw SWEDecodeError.unsupportedComponent(memberType, path)
            }

            members.append(BinaryMember(ref: normalise(ref: ref), kind: kind))
        }

        return DecodedBinaryEncoding(byteOrder: ByteOrder.parse(string(json["byteOrder"])),
                                     byteEncoding: string(json["byteEncoding"]) ?? "raw",
                                     members: members)
    }

    /// Every ref is stored "/"-prefixed so it compares equal to a FieldPath's
    /// description regardless of how the node wrote it.
    private static func normalise(ref: String) -> String {
        FieldPath(ref).description
    }

    // MARK: Value helpers
    //
    // JSONSerialization hands back NSNumber for every number, so an Int and a
    // Double are the same object with different readings. These funnel that
    // into one place; reading a count with `as? Int` directly would work for
    // 1024 and fail for 1024.0, which is exactly the sort of node-to-node
    // difference that must not reach the caller.

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return Bool(string) }
        return nil
    }

    private static func stripFragment(_ href: String) -> String {
        href.hasPrefix("#") ? String(href.dropFirst()) : href
    }

    /// A uom is `{"code": "deg"}` for a UCUM code or `{"href": "..."}` for a
    /// URI — Time components always use the latter.
    private static func uom(_ json: [String: Any]) -> (String?, String?) {
        guard let uom = json["uom"] as? [String: Any] else { return (nil, nil) }
        return (string(uom["code"]), string(uom["href"]))
    }

    private static func codeSpace(_ json: [String: Any]) -> String? {
        if let object = json["codeSpace"] as? [String: Any] { return string(object["href"]) }
        return string(json["codeSpace"])
    }

    private static func dataType(_ json: [String: Any]) -> SWEDataType? {
        guard let raw = string(json["dataType"]) else { return nil }
        return SWEDataType.from(uriSuffix: raw)
    }

    private static func numericConstraint(_ json: [String: Any]) -> AllowedValues? {
        guard let constraint = json["constraint"] as? [String: Any] else { return nil }
        let values = (constraint["values"] as? [Any])?.compactMap { double($0) }
        let intervals = (constraint["intervals"] as? [Any])?.compactMap { entry -> [Double]? in
            guard let pair = entry as? [Any] else { return nil }
            let bounds = pair.compactMap { double($0) }
            return bounds.count == 2 ? bounds : nil
        }
        let figures = int(constraint["significantFigures"])
        guard values != nil || intervals != nil || figures != nil else { return nil }
        return AllowedValues(values: values, intervals: intervals, significantFigures: figures)
    }

    private static func tokenConstraint(_ json: [String: Any]) -> AllowedTokens? {
        guard let constraint = json["constraint"] as? [String: Any] else { return nil }
        let values = (constraint["values"] as? [Any])?.compactMap { string($0) }
        let pattern = string(constraint["pattern"])
        guard values != nil || pattern != nil else { return nil }
        return AllowedTokens(values: values, pattern: pattern)
    }

    private static func nilValues(_ json: [String: Any]) -> [NilValue]? {
        guard let raw = json["nilValues"] as? [Any] else { return nil }
        let parsed = raw.compactMap { entry -> NilValue? in
            guard let object = entry as? [String: Any],
                  let reason = string(object["reason"]),
                  let value = string(object["value"]) else { return nil }
            return NilValue(reason: reason, value: value)
        }
        return parsed.isEmpty ? nil : parsed
    }
}
