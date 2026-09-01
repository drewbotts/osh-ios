import Foundation
import SwiftUI
import CoreLocation

// MARK: - COP map annotations
//
// Turning "what the node said" into "what is drawn".
//
// Split out from COPMapModel because this is the part with rules in it: which
// of three position sources wins, where a heading comes from when the position
// stream has none, where a line of bearing ends, and which system a designated
// target was observed from. The model above it only decides what to subscribe
// to.

extension COPMapModel {

    /// Every marker on the map, decimated to the cap.
    ///
    /// - Returns: the markers and whether anything had to be dropped, so the
    ///   caller can say so rather than silently drawing a partial harbour.
    func buildMarkers() -> (markers: [SystemMapView.Marker], decimated: Bool) {
        guard layers.nodeSystems else { return ([], false) }

        var result: [SystemMapView.Marker] = []
        for system in systems where system.hasPosition {
            result.append(contentsOf: markers(for: system))
        }
        // Target markers are not this system's position, so they are built
        // outside the loop above and for every system: a range finder with no
        // fix of its own still designates points, and those points are the
        // whole reason it is on the map.
        for system in systems {
            result.append(contentsOf: targetMarkers(for: system))
        }

        guard result.count > markerBudget else { return (result, false) }
        // Newest first, then cut. In a busy anchorage the vessels that
        // transmitted a minute ago are the ones worth drawing.
        return (Array(result.sorted { markerFreshness($0) > markerFreshness($1) }
                        .prefix(markerBudget)),
                true)
    }

    /// Markers for one system — one per entity for a multi-entity stream.
    func markers(for system: RemoteSystem) -> [SystemMapView.Marker] {
        let symbol = SystemGlyph.symbol(for: system)
        let tint = SystemGlyph.tint(for: system)
        let activity = activityState(system.id)

        switch system.positionKind {
        case .live:
            return system.locationDatastreams.flatMap { datastream -> [SystemMapView.Marker] in
                guard case .location(let paths, let headingPath) = datastream.role else { return [] }
                return entityMarkers(system: system,
                                     datastream: datastream,
                                     paths: paths,
                                     headingPath: headingPath,
                                     symbol: symbol,
                                     tint: tint,
                                     activity: activity,
                                     kind: .live)
            }

        case .reported:
            guard let datastream = system.reportedPositionDatastreams.first,
                  let embedded = datastream.embeddedPosition,
                  let observation = newest(systemId: system.id, datastreamId: datastream.id),
                  let point = TrackPoint.from(observation, paths: embedded.location, accuracy: nil)
            else { return [] }

            return [SystemMapView.Marker(
                id: system.id,
                coordinate: point.coordinate,
                symbol: symbol,
                headingDegrees: embedded.headingPath
                    .flatMap { observation.values[$0]?.asDouble }
                    ?? orientationHeading(system: system),
                kind: .reported,
                tint: tint,
                label: system.name,
                activity: activity)]

        case .deployed:
            guard let coordinate = system.fixedLocation else { return [] }
            return [SystemMapView.Marker(
                id: system.id,
                coordinate: coordinate,
                symbol: symbol,
                headingDegrees: nil,
                kind: .deployed,
                tint: tint,
                label: system.name,
                activity: activity)]

        case nil:
            return []
        }
    }

    private func entityMarkers(system: RemoteSystem,
                               datastream: RemoteDatastream,
                               paths: LocationPaths,
                               headingPath: FieldPath?,
                               symbol: String,
                               tint: Color,
                               activity: ActivityState,
                               kind: RemoteSystem.PositionKind) -> [SystemMapView.Marker] {

        let entities = session(for: system.id)?.entities(datastreamId: datastream.id)
            ?? newest(systemId: system.id, datastreamId: datastream.id).map { [(key: "", observation: $0)] }
            ?? []

        // Falls back to the system's own attitude stream: an Android phone
        // publishes its position and its orientation as two datastreams, and
        // one rotated marker is what a user means by "which way is it facing".
        let fallbackHeading = orientationHeading(system: system)

        return entities.compactMap { entity in
            guard let point = TrackPoint.from(entity.observation, paths: paths, accuracy: nil)
            else { return nil }
            return SystemMapView.Marker(
                id: entity.key.isEmpty ? system.id : "\(system.id)#\(entity.key)",
                coordinate: point.coordinate,
                symbol: symbol,
                headingDegrees: headingPath.flatMap { entity.observation.values[$0]?.asDouble }
                    ?? fallbackHeading,
                kind: kind,
                tint: tint,
                label: entity.key.isEmpty ? system.name : entity.key,
                activity: activity)
        }
    }

    /// Heading from a single-entity orientation stream, when there is exactly
    /// one. More than one attitude output and there is no basis for choosing.
    func orientationHeading(system: RemoteSystem) -> Double? {
        guard let (datastream, paths) = system.soleOrientation,
              let observation = newest(systemId: system.id, datastreamId: datastream.id)
        else { return nil }
        return paths.heading(from: observation)
    }

    // MARK: Bearing lines

    /// A line per bearing datastream that has ever produced an observation.
    func buildBearingLines() -> [SystemMapView.BearingLine] {
        guard layers.nodeSystems, layers.bearingLines else { return [] }
        return systems.flatMap { bearingLines(for: $0) }
    }

    func bearingLines(for system: RemoteSystem) -> [SystemMapView.BearingLine] {
        guard let origin = originForBearings(system) else { return [] }

        return system.bearingDatastreams.compactMap { datastream in
            guard case .bearing(let paths) = datastream.role,
                  let observation = newest(systemId: system.id, datastreamId: datastream.id),
                  let angle = observation.values[paths.angle]?.asDouble,
                  angle.isFinite else { return nil }

            let quality = paths.quality.flatMap { observation.values[$0]?.asDouble }
            let ceiling = qualityCeiling(system: system, datastream: datastream, paths: paths)

            return SystemMapView.BearingLine(
                id: datastream.id,
                start: origin,
                // Geodesic, never a screen-space rotation: at 60° north a
                // Mercator projection would turn a 45° bearing into a 63° line.
                end: BearingGeometry.destination(from: origin,
                                                 bearingDegrees: angle,
                                                 distanceMeters: BearingStyle.lineLength),
                observedAt: observation.phenomenonTime,
                isStrong: quality != nil && ceiling > 0
                    && quality! >= ceiling * BearingStyle.strongQualityFraction)
        }
    }

    /// Where a system's bearing lines start.
    ///
    /// A DOA record usually carries the station's own coordinates, so its
    /// embedded position is preferred over the system's marker: the two agree
    /// when both exist, and only one of them exists when the station has no
    /// separate position stream.
    private func originForBearings(_ system: RemoteSystem) -> CLLocationCoordinate2D? {
        for datastream in system.bearingDatastreams {
            guard let embedded = datastream.embeddedPosition,
                  let observation = newest(systemId: system.id, datastreamId: datastream.id),
                  let point = TrackPoint.from(observation, paths: embedded.location, accuracy: nil)
            else { continue }
            return point.coordinate
        }
        return markers(for: system).first?.coordinate
    }

    /// The strongest quality seen recently on this stream, so "strong" means
    /// strong for this receiver rather than against an absolute number that
    /// would be meaningless across confidence, RSSI and power.
    private func qualityCeiling(system: RemoteSystem,
                                datastream: RemoteDatastream,
                                paths: BearingPaths) -> Double {
        guard let qualityPath = paths.quality else { return 0 }
        let history = session(for: system.id)?.history[datastream.id] ?? []
        let values = history.compactMap { $0.values[qualityPath]?.asDouble }.filter(\.isFinite)
        return values.max() ?? 0
    }

    // MARK: Targets

    /// A crosshair at every currently-designated target on this system.
    ///
    /// One per (datastream, entity), and only the latest: `entities` already
    /// keeps the newest observation per bucket, so a range finder that has
    /// fired forty times this afternoon draws one target, not forty. The rest
    /// are reachable through the history layer.
    func targetMarkers(for system: RemoteSystem) -> [SystemMapView.Marker] {
        let activity = activityState(system.id)

        return system.targetDatastreams.flatMap { datastream -> [SystemMapView.Marker] in
            guard case .target(let paths) = datastream.role else { return [] }

            return targets(system: system, datastream: datastream).map { target in
                SystemMapView.Marker(
                    id: target.markerId,
                    coordinate: target.coordinate,
                    symbol: SystemGlyph.targetMarkerSymbol,
                    // Never rotated. A target is a point someone else is
                    // looking at; it has no facing of its own, and the azimuth
                    // in the record is the *source's* line of sight.
                    headingDegrees: nil,
                    kind: .live,
                    tint: SystemGlyph.tint(for: datastream.role),
                    label: label(of: target, paths: paths),
                    activity: activity)
            }
        }
    }

    /// The lines and the history dots, in one pass so the "already drawn"
    /// exclusion is computed once.
    func buildTargetOverlays()
        -> (lines: [SystemMapView.TargetLine], history: [SystemMapView.TargetDot]) {

        guard layers.nodeSystems else { return ([], []) }

        var lines: [SystemMapView.TargetLine] = []
        var history: [SystemMapView.TargetDot] = []

        for system in systems {
            for datastream in system.targetDatastreams {
                let current = targets(system: system, datastream: datastream)

                for target in current {
                    guard let source = target.source else { continue }
                    guard let origin = source.coordinate else {
                        noteSourceWithoutPosition(datastreamId: datastream.id, source: source)
                        continue
                    }
                    lines.append(SystemMapView.TargetLine(
                        id: target.markerId,
                        start: origin,
                        end: target.coordinate,
                        observedAt: target.observedAt))
                }

                if layers.targetHistory {
                    history.append(contentsOf: pastTargets(system: system,
                                                            datastream: datastream,
                                                            excluding: current))
                }
            }
        }
        return (lines, history)
    }

    /// One designated target, resolved far enough to draw.
    struct DrawnTarget {
        let markerId: String
        let entityKey: String
        let coordinate: CLLocationCoordinate2D
        let observedAt: Date
        let observation: ParsedObservation
        /// nil only when the datastream is not a target stream.
        let source: TargetSourceResolver.SourceRef?
    }

    /// The current target per entity on one datastream.
    func targets(system: RemoteSystem, datastream: RemoteDatastream) -> [DrawnTarget] {
        guard case .target(let paths) = datastream.role else { return [] }

        let entities = session(for: system.id)?.entities(datastreamId: datastream.id)
            ?? newest(systemId: system.id, datastreamId: datastream.id)
                .map { [(key: "", observation: $0)] }
            ?? []

        return entities.compactMap { entity in
            guard let point = TrackPoint.from(entity.observation,
                                             paths: paths.location,
                                             accuracy: nil) else { return nil }
            let source = TargetSourceResolver.source(
                for: entity.observation,
                datastream: datastream,
                owner: system,
                systems: systems,
                localDevice: localDevice,
                position: { self.currentPosition(of: $0) })

            return DrawnTarget(
                markerId: "\(system.id)#target-\(datastream.id)-\(entity.key)",
                entityKey: entity.key,
                coordinate: point.coordinate,
                observedAt: entity.observation.phenomenonTime,
                observation: entity.observation,
                source: source)
        }
    }

    /// Earlier targets on this datastream, oldest first and faintest oldest.
    ///
    /// Read from the session's ring, so it is only ever as deep as the app has
    /// actually seen — a range finder's whole archive is not fetched to draw
    /// twenty dots.
    private func pastTargets(system: RemoteSystem,
                             datastream: RemoteDatastream,
                             excluding current: [DrawnTarget]) -> [SystemMapView.TargetDot] {
        guard case .target(let paths) = datastream.role else { return [] }

        let drawn = Set(current.map(\.observedAt))
        let ring = (session(for: system.id)?.history[datastream.id] ?? [])
            .filter { !drawn.contains($0.phenomenonTime) }
            .suffix(TargetStyle.historyLimit)
        guard !ring.isEmpty else { return [] }

        return ring.enumerated().compactMap { index, observation in
            guard let point = TrackPoint.from(observation, paths: paths.location, accuracy: nil)
            else { return nil }
            // Oldest faintest, across a range that stays visible at both ends.
            let fraction = ring.count == 1 ? 1 : Double(index) / Double(ring.count - 1)
            return SystemMapView.TargetDot(
                id: "\(datastream.id)#past-\(observation.phenomenonTime.timeIntervalSince1970)",
                coordinate: point.coordinate,
                opacity: 0.2 + 0.35 * fraction)
        }
    }

    /// A target's chip: what the record said about getting there, or failing
    /// that what it is.
    private func label(of target: DrawnTarget, paths: TargetPaths) -> String {
        let range = paths.range.flatMap { target.observation.values[$0]?.asDouble }
        let azimuth = paths.azimuth.flatMap { target.observation.values[$0]?.asDouble }
        if let text = TargetStyle.label(rangeMeters: range, azimuthDegrees: azimuth) {
            return text
        }
        return target.entityKey.isEmpty ? "Target" : target.entityKey
    }

    // MARK: Styling

    private func markerFreshness(_ marker: SystemMapView.Marker) -> Date {
        let systemId = marker.id.split(separator: "#").first.map(String.init) ?? marker.id
        guard let system = systems.first(where: { $0.id == systemId }) else { return .distantPast }
        return system.datastreams
            .compactMap { newest(systemId: system.id, datastreamId: $0.id)?.phenomenonTime }
            .max() ?? .distantPast
    }
}
