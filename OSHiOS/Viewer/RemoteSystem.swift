import Foundation
import CoreLocation

// MARK: - EmbeddedPosition

/// A position a datastream carries incidentally, rather than as its subject.
///
/// KrakenSDR's settings output is the motivating case: the stream is
/// configuration, but it states where the station stands and which way its
/// array faces. Without this the node's most interesting system would have no
/// marker on the map at all.
struct EmbeddedPosition: Equatable, Sendable {
    let location: LocationPaths
    let headingPath: FieldPath?
}

// MARK: - RemoteDatastream

/// One datastream on a node, resolved far enough to render.
struct RemoteDatastream: Identifiable, Sendable {

    let summary: DatastreamSummary
    let schema: SWESchemaDecoder.DatastreamSchema?
    /// nil only when `schemaError` is set: a stream whose schema would not
    /// decode has no parser tree, and a decoder that returned nothing would be
    /// a lie the views would have to special-case anyway.
    let decoder: DatastreamDecoder?
    let role: DatastreamRole
    let entityKeyPath: FieldPath?
    let embeddedPosition: EmbeddedPosition?
    /// Non-nil when the node's schema could not be read. The role is `.generic`
    /// and the browser shows "schema not understood" with this text.
    let schemaError: String?

    var id: String { summary.id }
    var name: String { summary.name }

    /// The record this stream's observations map onto, when there is one.
    var recordSchema: DataRecord? { schema?.recordSchema }

    // MARK: Building

    /// Classifies a datastream whose schema decoded.
    init(summary: DatastreamSummary,
         schema: SWESchemaDecoder.DatastreamSchema,
         decoder: DatastreamDecoder) {

        let record = schema.recordSchema
        let role = DatastreamRoleInference.role(schema: record,
                                                encoding: schema.recordEncoding,
                                                datastreamName: summary.name)

        self.summary = summary
        self.schema = schema
        self.decoder = decoder
        self.role = role
        self.entityKeyPath = EntityKeyInference.entityKeyPath(schema: record, role: role)
        self.embeddedPosition = Self.embeddedPosition(in: record, role: role)
        self.schemaError = nil
    }

    /// A datastream whose schema the app could not read. Still listed, still
    /// drillable into the raw JSON — a stream that cannot be classified is a
    /// thing to show, not a thing to hide.
    init(summary: DatastreamSummary, schemaError: String) {
        self.summary = summary
        self.schema = nil
        self.decoder = nil
        self.role = .generic
        self.entityKeyPath = nil
        self.embeddedPosition = nil
        self.schemaError = schemaError
    }

    /// The position a record states about itself.
    ///
    /// nil for a `.location` stream: there the position *is* the role, and
    /// duplicating it would give the map two sources for one marker.
    static func embeddedPosition(in record: DataRecord,
                                 role: DatastreamRole) -> EmbeddedPosition? {
        if case .location = role { return nil }
        guard let resolved = LocationPaths.resolveDetailed(in: record) else { return nil }
        return EmbeddedPosition(location: resolved.paths,
                                headingPath: HeadingPath.resolve(in: record, near: resolved))
    }
}

// MARK: - RemoteSystem

/// A system on a node, with everything the viewer needs to draw it.
struct RemoteSystem: Identifiable, Sendable {

    let summary: SystemSummary
    let subsystems: [SystemSummary]
    let datastreams: [RemoteDatastream]
    let controlStreamCount: Int
    /// Where the system resource itself says it is — a deployment, not a fix.
    let fixedLocation: CLLocationCoordinate2D?

    var id: String { summary.id }
    var name: String { summary.name }

    // MARK: Position

    /// Where a marker's coordinates come from, best first.
    enum PositionKind: Sendable, Equatable {
        /// A `.location` datastream — the system reports where it is, live.
        case live
        /// Some datastream states a position in passing (`embeddedPosition`).
        case reported
        /// Only the system resource has a geometry: "installed here".
        case deployed
    }

    /// nil when nothing anywhere says where this system is.
    var positionKind: PositionKind? {
        if locationDatastreams.first != nil { return .live }
        if reportedPositionDatastreams.first != nil { return .reported }
        if fixedLocation != nil { return .deployed }
        return nil
    }

    var hasPosition: Bool { positionKind != nil }

    /// Datastreams whose subject is a position.
    var locationDatastreams: [RemoteDatastream] {
        datastreams.filter { if case .location = $0.role { return true } else { return false } }
    }

    /// Datastreams that state a position in passing, best first.
    ///
    /// One that also states a heading wins, whatever the node's listing order:
    /// a KrakenSDR reports its position twice — bare on every LOB, and beside
    /// the array heading in its settings — and only one of those can rotate the
    /// marker.
    var reportedPositionDatastreams: [RemoteDatastream] {
        datastreams
            .filter { $0.embeddedPosition != nil }
            .enumerated()
            .sorted { left, right in
                let leftHasHeading = left.element.embeddedPosition?.headingPath != nil
                let rightHasHeading = right.element.embeddedPosition?.headingPath != nil
                if leftHasHeading != rightHasHeading { return leftHasHeading }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    /// Direction-finding streams. More than one is ordinary — a station may
    /// track several emitters.
    var bearingDatastreams: [RemoteDatastream] {
        datastreams.filter { if case .bearing = $0.role { return true } else { return false } }
    }

    /// A single-entity orientation stream, which is how a phone's separate
    /// location and attitude outputs become one rotated marker.
    var soleOrientation: (datastream: RemoteDatastream, paths: OrientationPaths)? {
        let matches = datastreams.compactMap { datastream -> (RemoteDatastream, OrientationPaths)? in
            guard case .orientation(let paths) = datastream.role else { return nil }
            return (datastream, paths)
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    // MARK: Character

    /// What this system mostly is, for its icon and its map treatment.
    var primaryRole: DatastreamRole {
        datastreams.map(\.role).max { $0.priority < $1.priority } ?? .generic
    }

    /// Streams worth opening, most telling first. Bearing and
    /// embedded-position streams rank just under position and attitude: they
    /// are low-rate, and they are what puts a marker on the map at all.
    var streamsByViewingPriority: [RemoteDatastream] {
        datastreams.sorted { left, right in
            let leftRank = Self.viewingRank(left)
            let rightRank = Self.viewingRank(right)
            if leftRank != rightRank { return leftRank > rightRank }
            return left.id < right.id
        }
    }

    private static func viewingRank(_ datastream: RemoteDatastream) -> Int {
        switch datastream.role {
        case .location:    return 100
        case .orientation: return 90
        case .bearing:     return 80
        default:
            return datastream.embeddedPosition != nil ? 70 : datastream.role.priority
        }
    }
}
