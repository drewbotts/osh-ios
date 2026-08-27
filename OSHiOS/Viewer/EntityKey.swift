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
// Only location streams are grouped. Every stream has identifiers in it
// somewhere — a serial number, a station name, a channel — and splitting a
// weather station's readings by its own serial number would produce one bucket
// and a great deal of ceremony.

enum EntityKeyInference {

    /// Path of the field identifying which real-world object an observation is
    /// about, or nil when the stream describes exactly one.
    static func entityKeyPath(schema: DataRecord, role: DatastreamRole) -> FieldPath? {
        guard case .location = role else { return nil }

        let identifiers = SchemaWalker.leaves(of: schema).filter {
            $0.component is SWEText || $0.component is SWECategory
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
