import Foundation

// MARK: - EntityKeyInference
//
// One datastream, many things.
//
// An AIS receiver publishes every vessel in range on a single `vesselLocation`
// stream: consecutive observations describe different ships, and a viewer that
// treated the newest one as "the position" would draw a single marker
// teleporting around the harbour. The MMSI in each record is what separates
// them, and finding it is the whole job here.
//
// Only location and target streams are grouped. Every stream has identifiers in
// it somewhere — a serial number, a station name, a channel — and splitting a
// weather station's readings by its own serial number would produce one bucket
// and a great deal of ceremony. A target stream earns grouping because one
// range finder designates many targets, and only the latest per target belongs
// on the map.

enum EntityKeyInference {

    /// Path of the field identifying which real-world object an observation is
    /// about, or nil when the stream describes exactly one.
    static func entityKeyPath(schema: DataRecord, role: DatastreamRole) -> FieldPath? {
        // A target stream is grouped for the same reason a location stream is:
        // one range finder can designate several targets, and only the latest
        // per target belongs on the map. Its source identifier is excluded — it
        // names who was looking, not what was looked at, and keying by it would
        // collapse every target from one observer into one.
        var excluded: FieldPath?
        switch role {
        case .location:
            break
        case .target(let paths):
            excluded = paths.sourceIdPath
        default:
            return nil
        }

        let identifiers = SchemaWalker.leaves(of: schema).filter {
            ($0.component is SWEText || $0.component is SWECategory) && $0.path != excluded
        }
        return DatastreamRoleInference
            .firstLeaf(in: identifiers, matchingAny: DatastreamRoleInference.Keywords.entity)?
            .path
    }

    /// The bucket an observation belongs in: the value at `path`, or "" when
    /// there is no key or the record did not carry one.
    ///
    /// An empty string rather than nil so `latest[dsId][key]` needs no optional
    /// dimension — a single-entity stream is simply a stream with one bucket.
    static func entityKey(of observation: ParsedObservation, at path: FieldPath?) -> String {
        guard let path, let value = observation.values[path] else { return "" }
        return value.asString
    }
}
