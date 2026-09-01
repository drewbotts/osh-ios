import SwiftUI
import MapKit

// MARK: - SystemMapView
//
// Markers, tracks, lines of bearing and designated targets, drawn from plain
// values.
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
        /// Freshness, resolved by the caller from ActivityTracker. Carried as a
        /// value so a hundred markers do not each observe the tracker.
        var activity: ActivityState = .live

        static func == (lhs: Marker, rhs: Marker) -> Bool {
            lhs.id == rhs.id
                && lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
                && lhs.headingDegrees == rhs.headingDegrees
                && lhs.kind == rhs.kind
                && lhs.label == rhs.label
                && lhs.activity == rhs.activity
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

    /// A line from a system to a point it designated as a target.
    ///
    /// Both ends are known, unlike a LOB's, so this is a segment rather than a
    /// ray and needs no geodesy: over the few hundred metres a range finder
    /// reaches, the great circle and the straight line are the same pixels.
    struct TargetLine: Identifiable, Equatable {
        let id: String
        /// The source's position now. Moves when the source does.
        let start: CLLocationCoordinate2D
        let end: CLLocationCoordinate2D
        /// When the designation was made — drives the fade.
        let observedAt: Date

        static func == (lhs: TargetLine, rhs: TargetLine) -> Bool {
            lhs.id == rhs.id
                && lhs.start.latitude == rhs.start.latitude
                && lhs.start.longitude == rhs.start.longitude
                && lhs.end.latitude == rhs.end.latitude
                && lhs.end.longitude == rhs.end.longitude
                && lhs.observedAt == rhs.observedAt
        }
    }

    /// A past target: a dot, no line, no label.
    struct TargetDot: Identifiable, Equatable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        /// 1 for the most recent of the set, fading with age.
        var opacity: Double = 1

        static func == (lhs: TargetDot, rhs: TargetDot) -> Bool {
            lhs.id == rhs.id
                && lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
                && lhs.opacity == rhs.opacity
        }
    }

    /// A circle of positional uncertainty — this device's GPS accuracy.
    struct AccuracyCircle: Equatable {
        let center: CLLocationCoordinate2D
        let radiusMeters: CLLocationDistance

        static func == (lhs: AccuracyCircle, rhs: AccuracyCircle) -> Bool {
            lhs.center.latitude == rhs.center.latitude
                && lhs.center.longitude == rhs.center.longitude
                && lhs.radiusMeters == rhs.radiusMeters
        }
    }

    let markers: [Marker]
    var bearingLines: [BearingLine] = []
    var targetLines: [TargetLine] = []
    /// Past targets, drawn only when the caller's history layer is on.
    var targetHistory: [TargetDot] = []
    /// Recent paths, one per entity or datastream.
    var tracks: [[CLLocationCoordinate2D]] = []
    var accuracyCircle: AccuracyCircle?
    /// While non-nil the camera follows this coordinate at a steady zoom
    /// instead of refitting to every marker. This device's fix is the only
    /// caller: a map that rescaled to the whole route on each new point would
    /// be unusable while walking.
    var followCoordinate: CLLocationCoordinate2D?
    var showsControls = true
    var isInteractive = true
    /// The map's "Labels" layer toggle.
    var showsLabels = true
    /// Drawn scaled up and ringed. nil when nothing is selected.
    var selectedMarkerId: String?
    /// Group markers that sit within a thumb's width of each other.
    var clustersMarkers = true
    /// Never grouped — this device's marker.
    var unclusterableIds: Set<String> = []
    /// Reports how much grouping happened, for a caller's legend.
    var grouping: Binding<MarkerClustering.Summary>?
    var onSelect: ((Marker) -> Void)?
    /// A cluster whose members are all at the same coordinate, which zooming
    /// can never separate. The host lists them instead.
    var onSelectCoincidentCluster: ((MarkerClustering.Cluster) -> Void)?

    @State private var camera: MapCameraPosition = .automatic
    @State private var hasFramed = false
    /// Ticks so a bearing line's fade is re-evaluated without new data.
    @State private var now = Date()

    /// The camera's current region and the map's size in points — the two
    /// numbers clustering needs, and the only reason this view watches the
    /// camera at all.
    @State private var region: MKCoordinateRegion?
    @State private var viewSize: CGSize = .zero
    /// The drawn annotations, recomputed when something they depend on changes
    /// rather than inside `body`. Grouping is a comparison per pair, and a body
    /// that recomputed it — once for the annotations, once for the summary,
    /// once for the change check — would do it three times per redraw for a
    /// result that only moves when the markers or the camera do.
    @State private var entries: [MarkerClustering.Entry] = []

    // MARK: Body

    var body: some View {
        Map(position: $camera) {
            if let accuracyCircle, accuracyCircle.radiusMeters > 0 {
                MapCircle(center: accuracyCircle.center, radius: accuracyCircle.radiusMeters)
                    .foregroundStyle(.blue.opacity(0.15))
                    .stroke(.blue.opacity(0.5), lineWidth: 1)
            }

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

            ForEach(targetLines) { line in
                MapPolyline(coordinates: [line.start, line.end])
                    .stroke(.red.opacity(TargetStyle.opacity(at: line.observedAt, now: now)),
                            lineWidth: TargetStyle.lineWidth)
            }

            ForEach(targetHistory) { dot in
                Annotation("", coordinate: dot.coordinate) {
                    Circle()
                        .fill(.red.opacity(dot.opacity))
                        .frame(width: TargetStyle.historyDotSize,
                               height: TargetStyle.historyDotSize)
                        .overlay { Circle().strokeBorder(.white.opacity(0.7), lineWidth: 0.5) }
                        .accessibilityLabel("past target")
                }
                .annotationTitles(.hidden)
            }

            ForEach(entries) { entry in
                Annotation("", coordinate: entry.coordinate) {
                    switch entry {
                    case .single(let marker):
                        MarkerView(symbol: marker.symbol,
                                   headingDegrees: marker.headingDegrees,
                                   kind: marker.kind,
                                   tint: marker.tint,
                                   activity: marker.activity,
                                   label: marker.label,
                                   showsLabel: showsLabels,
                                   isSelected: marker.id == selectedMarkerId)
                            .onTapGesture { onSelect?(marker) }

                    case .cluster(let cluster):
                        ClusterMarkerView(count: cluster.count,
                                          tint: Self.tint(of: cluster),
                                          activity: cluster.activity,
                                          isSelected: cluster.members
                                              .contains { $0.id == selectedMarkerId })
                            .onTapGesture { open(cluster) }
                    }
                }
                // MarkerView draws its own label chip, which the Labels layer
                // can turn off; MapKit's title would ignore that toggle and
                // draw a second copy underneath.
                .annotationTitles(.hidden)
            }
        }
        .mapControls {
            if showsControls {
                MapCompass()
                MapScaleView()
            }
        }
        // Measured rather than assumed: a cluster cell is a number of points,
        // and the same span means very different crowding on a phone and on an
        // iPad.
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { viewSize = geometry.size }
                    .onChange(of: geometry.size) { _, size in viewSize = size }
            }
        }
        // `.onEnd` rather than `.continuous`: re-clustering every frame of a
        // pinch would rebuild every annotation at 60 Hz for a grouping the user
        // cannot read mid-gesture anyway. The pins settle when the fingers lift.
        .onMapCameraChange(frequency: .onEnd) { context in
            region = context.region
            recluster()
        }
        .onChange(of: markers) { _, _ in recluster() }
        .onChange(of: viewSize) { _, _ in recluster() }
        .onChange(of: clustersMarkers) { _, _ in recluster() }
        .onAppear { recluster() }
        .allowsHitTesting(isInteractive)
        .onChange(of: framingKey) { _, _ in frameIfNeeded() }
        .onAppear { frameIfNeeded() }
        .onChange(of: followCoordinate.map { [$0.latitude, $0.longitude] } ?? []) { _, _ in
            follow()
        }
        .onAppear { follow() }
        .animation(.easeInOut(duration: BearingStyle.refreshDuration), value: bearingLines)
        .animation(.easeInOut(duration: BearingStyle.refreshDuration), value: targetLines)
        .task {
            // A bearing or target line older than a minute fades; nothing else
            // would redraw it, so the view keeps its own slow clock.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                now = Date()
            }
        }
    }

    // MARK: Clustering

    /// Rebuilds what is drawn, and tells the caller how much was grouped.
    private func recluster() {
        guard clustersMarkers, let region else {
            entries = markers.map(MarkerClustering.Entry.single)
            grouping?.wrappedValue = .none
            return
        }
        let built = MarkerClustering.cluster(markers,
                                             span: region.span,
                                             viewSize: viewSize,
                                             pinned: unclusterableIds)
        entries = built
        let summary = MarkerClustering.summary(of: built)
        if grouping?.wrappedValue != summary { grouping?.wrappedValue = summary }
    }

    /// A cluster's colour: its members' shared tint, or a neutral when they
    /// disagree.
    ///
    /// Compared by description rather than by `==` because SwiftUI's Color
    /// equality is not defined across the ways a colour can be constructed, and
    /// a wrong answer here only ever costs the group its colour.
    static func tint(of cluster: MarkerClustering.Cluster) -> Color {
        let tints = Set(cluster.members.map { String(describing: $0.tint) })
        return tints.count == 1 ? cluster.members[0].tint : .secondary
    }

    /// Tapping a group zooms into it, which is the answer to "what is under
    /// there" almost every time. When every member is at the same coordinate
    /// no amount of zooming will help, so the host is asked to list them.
    private func open(_ cluster: MarkerClustering.Cluster) {
        guard cluster.isSeparable else {
            onSelectCoincidentCluster?(cluster)
            return
        }
        // Set before the animation as well as by the camera callback: a
        // programmatic move is not guaranteed to report itself, and a zoom that
        // did not re-cluster would leave the bubble sitting over the members it
        // had just spread out.
        region = cluster.boundingRegion
        withAnimation(.easeInOut(duration: 0.35)) {
            camera = .region(cluster.boundingRegion)
        }
        recluster()
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
        // Follow mode owns the camera; refitting to the markers underneath it
        // would yank the view away from the user's own position every time a
        // vessel appeared.
        guard followCoordinate == nil else { return }
        let coordinates = Self.framingCoordinates(
            markers.map(\.coordinate) + bearingLines.map(\.end) + targetLines.map(\.end))
        guard !coordinates.isEmpty else { return }
        guard !hasFramed || markers.count != lastFramedCount else { return }
        hasFramed = true
        lastFramedCount = markers.count

        let framed = Self.region(covering: coordinates)
        // Seeded here as well as from the camera callback: `.onMapCameraChange`
        // does not fire for the initial frame, and without a region the first
        // screenful would draw every overlapping pin ungrouped.
        region = framed
        withAnimation(.easeInOut(duration: 0.25)) {
            camera = .region(framed)
        }
        recluster()
    }

    @State private var lastFramedCount = -1

    /// Recenters on the followed coordinate at a fixed span.
    private func follow() {
        guard let followCoordinate else { return }
        let followed = MKCoordinateRegion(
            center: followCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005))
        region = followed
        withAnimation(.easeInOut(duration: 0.25)) {
            camera = .region(followed)
        }
        recluster()
    }

    /// The coordinates that get a vote on where the camera opens.
    ///
    /// Exactly (0, 0) is excluded whenever anything else is available. Null
    /// Island is almost never a position — it is a driver that was never given
    /// one, and the reference node's second Axis camera registers itself there
    /// — and letting it into the bounding box drags the camera into the Gulf of
    /// Guinea and squashes every real marker into a corner of the screen.
    ///
    /// The marker is still drawn. This is about the framing only: what the node
    /// said is shown, it just does not get to decide what the user looks at.
    static func framingCoordinates(_ coordinates: [CLLocationCoordinate2D])
        -> [CLLocationCoordinate2D] {
        let real = coordinates.filter { !isNullIsland($0) }
        return real.isEmpty ? coordinates : real
    }

    /// Within a millimetre of (0, 0). A real fix lands there about as often as
    /// a driver forgets to set one, which is to say never and constantly.
    static func isNullIsland(_ coordinate: CLLocationCoordinate2D) -> Bool {
        abs(coordinate.latitude) < 1e-8 && abs(coordinate.longitude) < 1e-8
    }

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
