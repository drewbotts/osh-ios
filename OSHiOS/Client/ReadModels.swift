import Foundation

// MARK: - Read models
//
// Lightweight views of the two Connected Systems resources this pass reads:
// systems and datastreams. They are deliberately *not* the full OGC models —
// this pass only needs enough to list, identify and drill into a resource.
//
// Decoding is tolerant on purpose. An OSH node can answer /systems as GeoJSON
// (identity in `properties`) or as SensorML-JSON (identity at the top level),
// and datastream payloads carry link-style keys such as "system@id". Every
// field except `id` is therefore optional or defaulted, so one unfamiliar key
// never costs the caller the whole list — a partly-populated row is far more
// useful than an error.

// MARK: - SystemSummary

struct SystemSummary: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let uid: String?
    let name: String
    let description: String?
    let type: String?
    let validTime: [String]?
    let parentSystemId: String?

    init(id: String,
         uid: String? = nil,
         name: String,
         description: String? = nil,
         type: String? = nil,
         validTime: [String]? = nil,
         parentSystemId: String? = nil) {
        self.id = id
        self.uid = uid
        self.name = name
        self.description = description
        self.type = type
        self.validTime = validTime
        self.parentSystemId = parentSystemId
    }

    private enum CodingKeys: String, CodingKey {
        case id, uid, name, description, type, validTime
        case uniqueId          // SensorML-JSON spelling of `uid`
        case label             // SensorML-JSON spelling of `name`
        case featureType       // GeoJSON spelling of `type`
        case properties        // GeoJSON: identity lives one level down
        case parentSystemId  = "parent@id"
        case parentSystemLink = "parent@link"
    }

    /// Keys that appear inside a GeoJSON feature's `properties` object.
    private enum PropertyKeys: String, CodingKey {
        case uid, name, description, validTime
        case uniqueId, label, featureType
        case type
        case parentSystemId = "parent@id"
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        // GeoJSON nests everything but `id`; SensorML-JSON keeps it flat.
        let props = try? root.nestedContainer(keyedBy: PropertyKeys.self, forKey: .properties)

        self.id = try root.decodeFlexibleString(forKey: .id) ?? ""

        self.uid = try root.decodeFlexibleString(forKey: .uid)
            ?? root.decodeFlexibleString(forKey: .uniqueId)
            ?? props?.decodeFlexibleString(forKey: .uid)
            ?? props?.decodeFlexibleString(forKey: .uniqueId)

        self.name = try root.decodeFlexibleString(forKey: .name)
            ?? root.decodeFlexibleString(forKey: .label)
            ?? props?.decodeFlexibleString(forKey: .name)
            ?? props?.decodeFlexibleString(forKey: .label)
            ?? self.id

        self.description = try root.decodeFlexibleString(forKey: .description)
            ?? props?.decodeFlexibleString(forKey: .description)

        // "type" at the root of a GeoJSON feature is always "Feature", which
        // says nothing about the system — prefer the featureType/type inside
        // properties and fall back to the root only for SensorML-JSON.
        let rootType = try root.decodeFlexibleString(forKey: .type)
        self.type = try props?.decodeFlexibleString(forKey: .featureType)
            ?? props?.decodeFlexibleString(forKey: .type)
            ?? root.decodeFlexibleString(forKey: .featureType)
            ?? (rootType == "Feature" ? nil : rootType)

        self.validTime = try root.decodeIfPresent([String].self, forKey: .validTime)
            ?? props?.decodeIfPresent([String].self, forKey: .validTime)

        self.parentSystemId = try root.decodeFlexibleString(forKey: .parentSystemId)
            ?? props?.decodeFlexibleString(forKey: .parentSystemId)
            ?? root.decodeFlexibleString(forKey: .parentSystemLink).map(ResourceLink.lastPathComponent)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(uid, forKey: .uid)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(validTime, forKey: .validTime)
        try container.encodeIfPresent(parentSystemId, forKey: .parentSystemId)
    }
}

// MARK: - DatastreamSummary

struct DatastreamSummary: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let outputName: String?
    let systemId: String?
    let validTime: [String]?
    let phenomenonTimeRange: [String]?
    let resultTimeRange: [String]?
    let formats: [String]?
    let live: Bool?

    init(id: String,
         name: String,
         outputName: String? = nil,
         systemId: String? = nil,
         validTime: [String]? = nil,
         phenomenonTimeRange: [String]? = nil,
         resultTimeRange: [String]? = nil,
         formats: [String]? = nil,
         live: Bool? = nil) {
        self.id = id
        self.name = name
        self.outputName = outputName
        self.systemId = systemId
        self.validTime = validTime
        self.phenomenonTimeRange = phenomenonTimeRange
        self.resultTimeRange = resultTimeRange
        self.formats = formats
        self.live = live
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, outputName, validTime, formats, live
        case label                            // SensorML-JSON spelling of `name`
        // The node spells these without the "Range" suffix; both are accepted
        // because the OGC schema and OSH's own docs use the longer form.
        case phenomenonTime, resultTime
        case phenomenonTimeRange, resultTimeRange
        case systemId   = "system@id"
        case systemLink = "system@link"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try container.decodeFlexibleString(forKey: .id) ?? ""
        self.outputName = try container.decodeFlexibleString(forKey: .outputName)
        self.name = try container.decodeFlexibleString(forKey: .name)
            ?? container.decodeFlexibleString(forKey: .label)
            ?? self.outputName
            ?? self.id

        // "system@id" when the node inlines it, otherwise the tail of "system@link".
        self.systemId = try container.decodeFlexibleString(forKey: .systemId)
            ?? container.decodeLinkHref(forKey: .systemLink).map(ResourceLink.lastPathComponent)

        self.validTime           = try container.decodeIfPresent([String].self, forKey: .validTime)
        self.phenomenonTimeRange = try container.decodeIfPresent([String].self, forKey: .phenomenonTime)
            ?? container.decodeIfPresent([String].self, forKey: .phenomenonTimeRange)
        self.resultTimeRange     = try container.decodeIfPresent([String].self, forKey: .resultTime)
            ?? container.decodeIfPresent([String].self, forKey: .resultTimeRange)
        self.formats             = try container.decodeIfPresent([String].self, forKey: .formats)
        self.live                = try container.decodeIfPresent(Bool.self, forKey: .live)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(outputName, forKey: .outputName)
        try container.encodeIfPresent(systemId, forKey: .systemId)
        try container.encodeIfPresent(validTime, forKey: .validTime)
        try container.encodeIfPresent(phenomenonTimeRange, forKey: .phenomenonTimeRange)
        try container.encodeIfPresent(resultTimeRange, forKey: .resultTimeRange)
        try container.encodeIfPresent(formats, forKey: .formats)
        try container.encodeIfPresent(live, forKey: .live)
    }
}

// MARK: - ControlStreamSummary

/// A control stream, as much of one as a read-only viewer needs.
///
/// Pass 4 adds command encoding and a params schema; until then this exists so
/// the browser can list what a system accepts rather than silently omitting it.
struct ControlStreamSummary: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let inputName: String?
    let systemId: String?

    init(id: String, name: String, inputName: String? = nil, systemId: String? = nil) {
        self.id = id
        self.name = name
        self.inputName = inputName
        self.systemId = systemId
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, inputName
        case label
        case systemId   = "system@id"
        case systemLink = "system@link"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeFlexibleString(forKey: .id) ?? ""
        self.inputName = try container.decodeFlexibleString(forKey: .inputName)
        self.name = try container.decodeFlexibleString(forKey: .name)
            ?? container.decodeFlexibleString(forKey: .label)
            ?? self.inputName
            ?? self.id
        self.systemId = try container.decodeFlexibleString(forKey: .systemId)
            ?? container.decodeLinkHref(forKey: .systemLink).map(ResourceLink.lastPathComponent)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(inputName, forKey: .inputName)
        try container.encodeIfPresent(systemId, forKey: .systemId)
    }
}

// MARK: - Collection envelope

/// Connected Systems collection responses: `{ "items": [...], "links": [...] }`.
/// Some deployments answer with a bare array instead, so both are accepted.
struct ItemsResponse<Item: Decodable>: Decodable {
    let items: [Item]

    private enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
           let items = try? keyed.decode([Item].self, forKey: .items) {
            self.items = items
            return
        }
        var unkeyed = try decoder.unkeyedContainer()
        var items: [Item] = []
        while !unkeyed.isAtEnd {
            items.append(try unkeyed.decode(Item.self))
        }
        self.items = items
    }
}

// MARK: - Decoding helpers

/// A `{ "href": ... }` link object, the alternative to a bare href string.
private struct HRefLink: Decodable { let href: String? }

enum ResourceLink {
    /// The id at the end of a resource URL: ".../systems/abc123" → "abc123".
    static func lastPathComponent(_ href: String) -> String {
        URL(string: href)?.lastPathComponent ?? href
    }
}

private extension KeyedDecodingContainer {

    /// Decodes a value that the node may express as a string or as a number.
    /// Resource ids in particular come back either way depending on the store.
    func decodeFlexibleString(forKey key: Key) throws -> String? {
        if let string = try? decodeIfPresent(String.self, forKey: key) { return string }
        if let int = try? decodeIfPresent(Int.self, forKey: key) { return String(int) }
        return nil
    }

    /// A link value, which is either a bare href string or a `{ "href": ... }` object.
    func decodeLinkHref(forKey key: Key) -> String? {
        if let string = try? decodeIfPresent(String.self, forKey: key) { return string }
        if let link = try? decodeIfPresent(HRefLink.self, forKey: key) { return link.href }
        return nil
    }
}
