import Foundation

// MARK: - LocationPaths
//
// Where latitude, longitude and altitude live inside a Location record.
//
// Resolved from the schema rather than hardcoded: a datastream read back from
// an OSH node may name its coordinates differently from the ones this app
// registers, and the map has to plot it either way. Definitions are checked
// first because they are the interoperable part; names are the fallback.
//
// The search is recursive (Pass 3b). A position is not always a top-level
// field: KrakenSDR reports its station's fix inside a settings record, at
// /stationConfig/location, and a viewer that only looked one level down would
// draw no marker for a system that plainly says where it is.

struct LocationPaths: Equatable, Sendable {
    let latitude: FieldPath
    let longitude: FieldPath
    let altitude: FieldPath?

    /// A location vector found in a schema, together with the record it sits
    /// in.
    ///
    /// The container is what makes heading resolution work: a heading belongs
    /// to the position it was measured with, so the Quantity *beside* the
    /// vector is a better answer than a same-named field three records away.
    struct Resolved: Sendable {
        let paths: LocationPaths
        /// Fields of the record the location vector is a field of. The root
        /// record's own fields when the vector is top-level.
        let siblings: [DataField]
        /// Path of that containing record — empty for the root record.
        let containerPath: FieldPath
    }

    /// Finds the first Vector in `schema` that a definition marks as a
    /// location, and resolves its coordinates. nil when there is none.
    static func resolve(in schema: DataRecord) -> LocationPaths? {
        resolveDetailed(in: schema)?.paths
    }

    /// As `resolve(in:)`, but keeps the containing record.
    ///
    /// Breadth before depth: every field of a record is examined before any
    /// nested record is descended into, so a schema with both a top-level fix
    /// and a buried one resolves to the top-level one — the same answer this
    /// returned before it learned to recurse.
    static func resolveDetailed(in schema: DataRecord) -> Resolved? {
        resolveDetailed(fields: schema.fields, base: FieldPath(components: []))
    }

    private static func resolveDetailed(fields: [DataField], base: FieldPath) -> Resolved? {
        for field in fields {
            guard let vector = field.component as? SWEVector,
                  vector.definition?.localizedCaseInsensitiveContains("Location") == true
            else { continue }

            let vectorPath = base.appending(field.name)
            guard let latitude  = coordinate(in: vector, base: vectorPath,
                                             definitionKeywords: ["Latitude"],
                                             names: ["lat", "latitude"]),
                  let longitude = coordinate(in: vector, base: vectorPath,
                                             definitionKeywords: ["Longitude"],
                                             names: ["lon", "lng", "longitude"])
            else { continue }

            let altitude = coordinate(in: vector, base: vectorPath,
                                      definitionKeywords: ["Altitude", "Height"],
                                      names: ["alt", "altitude", "height"])
            return Resolved(paths: LocationPaths(latitude: latitude,
                                                 longitude: longitude,
                                                 altitude: altitude),
                            siblings: fields,
                            containerPath: base)
        }

        // Nothing at this level: descend. A DataArray is not walked — a fix
        // repeated per element is a track, not this system's position.
        for field in fields {
            guard let record = field.component as? DataRecord else { continue }
            if let resolved = resolveDetailed(fields: record.fields,
                                              base: base.appending(field.name)) {
                return resolved
            }
        }
        return nil
    }

    private static func coordinate(in vector: SWEVector,
                                   base: FieldPath,
                                   definitionKeywords: [String],
                                   names: [String]) -> FieldPath? {
        for coordinate in vector.coordinates {
            guard let definition = coordinate.component.definition else { continue }
            if definitionKeywords.contains(where: { definition.localizedCaseInsensitiveContains($0) }) {
                return base.appending(coordinate.name)
            }
        }
        for coordinate in vector.coordinates
        where names.contains(coordinate.name.lowercased()) {
            return base.appending(coordinate.name)
        }
        return nil
    }
}

// MARK: - HeadingPath

/// Which field says where a thing is pointing.
///
/// Three spellings cover every schema on the reference node and both of this
/// app's own: a true heading (AIS `heading`, the app's Euler output), a plain
/// heading (KrakenSDR's `stationConfig/heading`), and course over ground, which
/// is a direction of travel rather than of facing and is therefore the last
/// resort rather than an equal.
enum HeadingPath {

    /// Definition keyword, then acceptable names, in preference order.
    private static let candidates: [(definition: String, names: [String])] = [
        ("TrueHeading",       ["trueheading", "heading"]),
        ("Heading",           ["heading", "yaw"]),
        ("CourseOverGround",  ["cog", "courseoverground", "course"])
    ]

    /// The heading Quantity that belongs with `location`.
    ///
    /// Siblings first, then the root record. A settings record carrying both a
    /// station heading and, say, a wind direction at top level must pick the
    /// station's.
    static func resolve(in schema: DataRecord, near location: LocationPaths.Resolved) -> FieldPath? {
        if let path = search(fields: location.siblings, base: location.containerPath) {
            return path
        }
        guard !location.containerPath.components.isEmpty else { return nil }
        return search(fields: schema.fields, base: FieldPath(components: []))
    }

    /// The heading Quantity at the top level of `schema`, ignoring position.
    static func resolveTopLevel(in schema: DataRecord) -> FieldPath? {
        search(fields: schema.fields, base: FieldPath(components: []))
    }

    private static func search(fields: [DataField], base: FieldPath) -> FieldPath? {
        for candidate in candidates {
            for field in fields {
                guard field.component is Quantity,
                      let definition = field.component.definition,
                      definition.localizedCaseInsensitiveContains(candidate.definition)
                else { continue }
                return base.appending(field.name)
            }
            for field in fields {
                guard field.component is Quantity,
                      candidate.names.contains(field.name.lowercased())
                else { continue }
                return base.appending(field.name)
            }
        }
        return nil
    }
}
