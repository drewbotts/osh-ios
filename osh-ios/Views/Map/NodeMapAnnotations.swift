import Foundation
import SwiftUI
import CoreLocation

// MARK: - Node map annotations
//
// Turning "what the node said" into "what is drawn".
//
// Split out from NodeMapModel because this is the part with rules in it: which
// of three position sources wins, where a heading comes from when the position
// stream has none, and where a line of bearing ends. The model above it only
// decides what to subscribe to.

extension NodeMapModel {

    /// Every marker on the map, decimated to the cap.
    ///
    /// - Returns: the markers and whether anything had to be dropped, so the
    ///   caller can say so rather than silently drawing a partial harbour.
    func buildMarkers() -> (markers: [SystemMapView.Marker], decimated: Bool) {
        var result: [SystemMapView.Marker] = []
        for system in systems where system.hasPosition {
            result.append(contentsOf: markers(for: system))
        }

        guard result.count > Self.maxMarkers else { return (result, false) }
        // Newest first, then cut. In a busy anchorage the vessels that
        // transmitted a minute ago are the ones worth drawing.
        return (Array(result.sorted { markerFreshness($0) > markerFreshness($1) }
                        .prefix(Self.maxMarkers)),
                true)
    }

    /// Markers for one system — one per entity for a multi-entity stream.
    func markers(for system: RemoteSystem) -> [SystemMapView.Marker] {
        let symbol = SystemGlyph.symbol(for: system)
        let tint = Self.tint(for: system)

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
                label: system.name)]

        case .deployed:
            guard let coordinate = system.fixedLocation else { return [] }
            return [SystemMapView.Marker(
                id: system.id,
                coordinate: coordinate,
                symbol: symbol,
                headingDegrees: nil,
                kind: .deployed,
                tint: tint,
                label: system.name)]

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
                label: entity.key.isEmpty ? system.name : entity.key)
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
        systems.flatMap { bearingLines(for: $0) }
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

    // MARK: Styling

    static func tint(for system: RemoteSystem) -> Color {
        switch system.primaryRole {
        case .video:       return .purple
        case .location:    return .blue
        case .orientation: return .indigo
        case .bearing:     return .orange
        case .chart:       return .teal
        case .timeseries:  return SystemGlyph.isWeather(system) ? .teal : .green
        case .status:      return .gray
        case .generic:     return .secondary
        }
    }

    private func markerFreshness(_ marker: SystemMapView.Marker) -> Date {
        let systemId = marker.id.split(separator: "#").first.map(String.init) ?? marker.id
        guard let system = systems.first(where: { $0.id == systemId }) else { return .distantPast }
        return system.datastreams
            .compactMap { newest(systemId: system.id, datastreamId: $0.id)?.phenomenonTime }
            .max() ?? .distantPast
    }
}
