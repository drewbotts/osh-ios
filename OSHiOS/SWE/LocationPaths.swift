import Foundation

// MARK: - LocationPaths
//
// Where latitude, longitude and altitude live inside a Location record.
//
// Resolved from the schema rather than hardcoded: a datastream read back from
// an OSH node may name its coordinates differently from the ones this app
// registers, and the map has to plot it either way. Definitions are checked
// first because they are the interoperable part; names are the fallback.

struct LocationPaths: Equatable, Sendable {
    let latitude: FieldPath
    let longitude: FieldPath
    let altitude: FieldPath?

    /// Finds the first Vector in `schema` that a definition marks as a
    /// location, and resolves its coordinates. nil when there is none.
    static func resolve(in schema: DataRecord) -> LocationPaths? {
        for field in schema.fields {
            guard let vector = field.component as? SWEVector,
                  vector.definition?.localizedCaseInsensitiveContains("Location") == true
            else { continue }

            let base = FieldPath(components: [field.name])
            guard let latitude  = coordinate(in: vector, base: base,
                                             definitionKeywords: ["Latitude"],
                                             names: ["lat", "latitude"]),
                  let longitude = coordinate(in: vector, base: base,
                                             definitionKeywords: ["Longitude"],
                                             names: ["lon", "lng", "longitude"])
            else { continue }

            let altitude = coordinate(in: vector, base: base,
                                      definitionKeywords: ["Altitude", "Height"],
                                      names: ["alt", "altitude", "height"])
            return LocationPaths(latitude: latitude, longitude: longitude, altitude: altitude)
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
