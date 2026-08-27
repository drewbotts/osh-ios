import SwiftUI
import MapKit

// MARK: - SystemMapView
//
// Markers, tracks and lines of bearing, drawn from plain values.
//
// One map for three callers: the dashboard's compact location card, its
// full-screen expansion, and the Node tab's map of every system on the node.
// They differ in what they pass, not in how anything is drawn — which is what
// keeps a rotated AIS marker looking the same wherever it appears.
//
// Deliberately knows nothing about RemoteSystem or SystemLiveSession. Its
// inputs are coordinates, headings and symbols, so the pieces that decide where
// a marker comes from can change without touching the drawing.

struct SystemMapView: View {

    // MARK: Inputs

    struct Marker: Identifiable, Equatable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let symbol: String
        /// Degrees clockwise from true north, or nil to draw the glyph plain.
        var headingDegrees: Double?
        var kind: RemoteSystem.PositionKind = .live
        var tint: Color = .accentColor
        /// Shown under the marker — a vessel's MMSI, a system's name.
        var label: String?

        static func == (lhs: Marker, rhs: Marker) -> Bool {
            lhs.id == rhs.id
                && lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
                && lhs.headingDegrees == rhs.headingDegrees
                && lhs.kind == rhs.kind
                && lhs.label == rhs.label
        }
    }

    /// A line of bearing already reduced to two coordinates.
    ///
    /// The endpoint is computed geodesically by the caller
    /// (`BearingGeometry.destination`) rather than here, so nothing in the view
    /// layer is ever tempted to rotate a line in screen space.
    struct BearingLine: Identifiable, Equatable {
        let id: String
        let start: CLLocationCoordinate2D
        let end: CLLocationCoordinate2D
        /// When the bearing was observed — drives the fade.
        let observedAt: Date
        /// True for a detection at or above the rolling quality threshold.
        var isStrong = false

        static func == (lhs: BearingLine, rhs: BearingLine) -> Bool {
            lhs.id == rhs.id
                && lhs.end.latitude == rhs.end.latitude
                && lhs.end.longitude == rhs.end.longitude
                && lhs.observedAt == rhs.observedAt
        }
    }

    let markers: [Marker]
    var bearingLines: [BearingLine] = []
    /// Recent paths, one per entity or datastream.
    var tracks: [[CLLocationCoordinate2D]] = []
    var showsControls = true
    var isInteractive = true
    var onSelect: ((Marker) -> Void)?

    @State private var camera: MapCameraPosition = .automatic
    @State private var hasFramed = false
    /// Ticks so a bearing line's fade is re-evaluated without new data.
    @State private var now = Date()

    // MARK: Body

    var body: some View {
        Map(position: $camera) {
            ForEach(tracks.indices, id: \.self) { index in
                if tracks[index].count >= 2 {
                    MapPolyline(coordinates: tracks[index])
                        .stroke(.blue.opacity(0.7), lineWidth: 3)
                }
            }

            ForEach(bearingLines) { line in
                // The glow goes underneath, so a strong detection reads as a
                // brighter line rather than a thicker one.
                if line.isStrong {
                    MapPolyline(coordinates: [line.start, line.end])
                        .stroke(.orange.opacity(BearingStyle.opacity(at: line.observedAt,
                                                                     now: now) * 0.35),
                                lineWidth: BearingStyle.lineWidth * 3)
                }
                MapPolyline(coordinates: [line.start, line.end])
                    .stroke(.orange.opacity(BearingStyle.opacity(at: line.observedAt, now: now)),
                            lineWidth: BearingStyle.lineWidth)
            }

            ForEach(markers) { marker in
                Annotation(marker.label ?? "", coordinate: marker.coordinate) {
                    HeadingMarker(symbol: marker.symbol,
                                  headingDegrees: marker.headingDegrees,
                                  kind: marker.kind,
                                  tint: marker.tint)
                        .onTapGesture { onSelect?(marker) }
                }
                .annotationTitles(marker.label == nil ? .hidden : .automatic)
            }
        }
        .mapControls {
            if showsControls {
                MapCompass()
                MapScaleView()
            }
        }
        .allowsHitTesting(isInteractive)
        .onChange(of: framingKey) { _, _ in frameIfNeeded() }
        .onAppear { frameIfNeeded() }
        .animation(.easeInOut(duration: BearingStyle.refreshDuration), value: bearingLines)
        .task {
            // A line older than a minute fades; nothing else would redraw it,
            // so the view keeps its own slow clock.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                now = Date()
            }
        }
    }

    // MARK: Framing

    /// Re-frames when the set of markers changes identity, not when one moves.
    ///
    /// A camera that refit on every position update would fight the user for
    /// control of the map on any stream faster than about 0.2 Hz.
    private var framingKey: String {
        markers.map(\.id).sorted().joined(separator: ",")
    }

    private func frameIfNeeded() {
        let coordinates = markers.map(\.coordinate) + bearingLines.map(\.end)
        guard !coordinates.isEmpty else { return }
        guard !hasFramed || markers.count != lastFramedCount else { return }
        hasFramed = true
        lastFramedCount = markers.count

        withAnimation(.easeInOut(duration: 0.25)) {
            camera = .region(Self.region(covering: coordinates))
        }
    }

    @State private var lastFramedCount = -1

    /// A region containing every coordinate, with margin, and a floor on the
    /// span so a single marker does not zoom to street level.
    static func region(covering coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                      span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 180))
        }
        var minLatitude = first.latitude, maxLatitude = first.latitude
        var minLongitude = first.longitude, maxLongitude = first.longitude
        for coordinate in coordinates {
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2,
                                           longitude: (minLongitude + maxLongitude) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLatitude - minLatitude) * 1.4, 0.01),
                longitudeDelta: max((maxLongitude - minLongitude) * 1.4, 0.01)))
    }
}
