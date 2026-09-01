import SwiftUI
import CoreLocation

// MARK: - COPMapView
//
// The common operating picture: one map, everything on it.
//
// This replaces a segmented control that made the user choose between what the
// phone was recording and what the node knew. That choice was always the wrong
// question — the value of an OSH node is that a phone's track, a camera's
// deployment point and a direction finder's line of bearing are *one* picture,
// and a picture you have to flip between is two pictures.
//
// So there is one map. This device draws itself from SensorSession and node
// systems draw themselves from COPMapModel, and neither can fail the other: a
// phone with no server configured still shows its own track, and a node with
// no phone fix still shows its systems. Layers turn parts of it off; nothing
// turns the map into a different map.

struct COPMapView: View {

    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var session: SensorSession
    @EnvironmentObject private var connections: NodeConnectionStore
    @EnvironmentObject private var activity: ActivityTracker
    @EnvironmentObject private var router: TabRouter

    @StateObject private var model = COPMapModel()

    @State private var selected: RemoteSystem?
    @State private var selectedMarkerId: String?
    @State private var isFollowingDevice = false
    /// A group of markers stacked on one coordinate, which zooming cannot pull
    /// apart. Listed instead.
    @State private var stackedCluster: MarkerClustering.Cluster?
    @State private var grouping = MarkerClustering.Summary.none

    // MARK: Body

    var body: some View {
        ZStack {
            SystemMapView(markers: markers,
                          bearingLines: model.bearingLines,
                          targetLines: model.targetLines,
                          targetHistory: layers.targetHistory ? model.targetHistory : [],
                          tracks: tracks,
                          accuracyCircle: layers.thisDevice ? DeviceLayer.accuracyCircle(session: session) : nil,
                          followCoordinate: followCoordinate,
                          showsLabels: layers.labels,
                          selectedMarkerId: selectedMarkerId,
                          clustersMarkers: layers.clusterMarkers,
                          unclusterableIds: [DeviceLayer.markerId],
                          grouping: $grouping,
                          onSelect: select,
                          onSelectCoincidentCluster: { stackedCluster = $0 })

            if markers.isEmpty { overlayMessage }
        }
        .safeAreaInset(edge: .bottom) { legend }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { layerMenu }
            if layers.thisDevice, session.currentFix != nil {
                ToolbarItem(placement: .topBarTrailing) { followButton }
            }
        }
        // Keeps the model's layer state and the persisted config in step in
        // both directions without either owning the other.
        .onAppear { model.layers = settings.config.mapLayers }
        .onChange(of: settings.config.mapLayers) { _, new in model.layers = new }
        .task(id: connections.active?.server.id) {
            await model.load(connection: connections.active)
        }
        // A target's line starts at its source, and the source is often this
        // phone. Pushed on every fix rather than read by the model, which has
        // no business knowing about SensorSession.
        .onAppear { model.setLocalDevice(localDeviceRef) }
        .onChange(of: localDeviceRef) { _, device in model.setLocalDevice(device) }
        .onAppear { consumePendingSelection() }
        .onChange(of: router.pendingMapSelection) { _, _ in consumePendingSelection() }
        .onDisappear { model.stopAll() }
        .sheet(item: $selected) { system in
            SystemMarkerSheet(system: system, model: model)
        }
        .sheet(item: $stackedCluster) { cluster in
            StackedMarkerSheet(cluster: cluster) { marker in
                stackedCluster = nil
                select(marker)
            }
        }
        .onChange(of: selected == nil) { _, dismissed in
            if dismissed { selectedMarkerId = nil }
        }
    }

    private var layers: MapLayers { settings.config.mapLayers }

    /// This device as a target-source candidate.
    private var localDeviceRef: TargetSourceResolver.LocalDeviceRef {
        TargetSourceResolver.LocalDeviceRef(
            systemId: connections.active.flatMap {
                SystemRegistration.cachedId(serverId: $0.server.id)
            },
            uid: SystemDescriptor.currentDeviceUID,
            markerId: DeviceLayer.markerId,
            coordinate: session.currentFix?.coordinate)
    }

    /// Selects the marker another screen asked for, and clears the request so
    /// coming back to the map later does not re-select it.
    private func consumePendingSelection() {
        guard let markerId = router.pendingMapSelection else { return }
        router.pendingMapSelection = nil
        selectedMarkerId = markerId
        guard markerId != DeviceLayer.markerId else {
            isFollowingDevice = true
            return
        }
        let systemId = markerId.split(separator: "#").first.map(String.init) ?? markerId
        selected = model.systems.first { $0.id == systemId }
    }

    // MARK: Composition

    /// The node's markers and this device's, in that order so the phone is
    /// drawn last and therefore on top of whatever it is standing in.
    private var markers: [SystemMapView.Marker] {
        var result = model.markers
        if layers.thisDevice,
           let device = DeviceLayer.marker(session: session,
                                           activity: activity.localDeviceActivity.state,
                                           isFollowed: isFollowingDevice) {
            result.append(device)
        }
        return result
    }

    private var tracks: [[CLLocationCoordinate2D]] {
        guard layers.tracks, layers.thisDevice else { return [] }
        let track = DeviceLayer.track(session: session)
        return track.isEmpty ? [] : [track]
    }

    private var followCoordinate: CLLocationCoordinate2D? {
        guard isFollowingDevice, layers.thisDevice else { return nil }
        return session.currentFix?.coordinate
    }

    // MARK: Selection

    private func select(_ marker: SystemMapView.Marker) {
        // The device marker has no dashboard to open; tapping it is how you
        // start and stop following your own position.
        guard marker.id != DeviceLayer.markerId else {
            isFollowingDevice.toggle()
            selectedMarkerId = isFollowingDevice ? marker.id : nil
            return
        }
        selectedMarkerId = marker.id
        selected = system(for: marker)
    }

    private func system(for marker: SystemMapView.Marker) -> RemoteSystem? {
        let systemId = marker.id.split(separator: "#").first.map(String.init) ?? marker.id
        return model.systems.first { $0.id == systemId }
    }

    // MARK: Chrome

    /// Every layer, plus the live switch, behind one button.
    ///
    /// A menu rather than a row of toggles because the map is the content here
    /// and chrome that permanently occupies a strip of it is chrome that has
    /// won an argument it should have lost.
    private var layerMenu: some View {
        Menu {
            Section("Layers") {
                toggle("This device", "iphone", \.thisDevice)
                toggle("Node systems", "square.stack.3d.up", \.nodeSystems)
                toggle("Tracks", "point.topleft.down.to.point.bottomright.curvepath", \.tracks)
                toggle("Bearing lines", "line.diagonal", \.bearingLines)
                toggle("Target history", "scope", \.targetHistory)
                toggle("Labels", "textformat", \.labels)
                toggle("Group nearby", "circle.grid.2x2", \.clusterMarkers)
            }
            Section {
                toggle("Live updates", "dot.radiowaves.up.forward", \.liveUpdates)
            }
        } label: {
            Label("Layers", systemImage: "square.3.layers.3d")
        }
    }

    private func toggle(_ title: String,
                        _ symbol: String,
                        _ path: WritableKeyPath<MapLayers, Bool>) -> some View {
        Toggle(isOn: Binding(
            get: { settings.config.mapLayers[keyPath: path] },
            set: { settings.config.mapLayers[keyPath: path] = $0 }
        )) {
            Label(title, systemImage: symbol)
        }
    }

    private var followButton: some View {
        Toggle(isOn: $isFollowingDevice) {
            Label("Follow", systemImage: isFollowingDevice ? "location.fill" : "location")
        }
        .toggleStyle(.button)
    }

    @ViewBuilder
    private var overlayMessage: some View {
        if model.isLoading {
            ProgressView("Loading systems…")
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if let error = model.error {
            ContentUnavailableView {
                Label("Cannot read the node", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
            .background(.regularMaterial)
        } else {
            ContentUnavailableView {
                Label("Nothing to show yet", systemImage: "mappin.slash")
            } description: {
                Text(emptyDescription)
            }
            .background(.regularMaterial)
        }
    }

    /// Why the map is empty, which is three different situations.
    private var emptyDescription: String {
        if !layers.nodeSystems && !layers.thisDevice {
            return "Every layer is switched off. Turn one on from the layers menu."
        }
        if connections.active == nil {
            return "No server is selected. Pick one on the Systems tab, or start a session to put this device on the map."
        }
        return "No system on this node reports a location, and this device has no fix yet."
    }

    @ViewBuilder
    private var legend: some View {
        if !markers.isEmpty {
            HStack(spacing: 10) {
                Text("\(markers.count) markers")
                if !model.bearingLines.isEmpty {
                    Label("\(model.bearingLines.count) LOB", systemImage: "line.diagonal")
                        .foregroundStyle(.orange)
                }
                if !model.targetLines.isEmpty {
                    Label("\(model.targetLines.count) targets", systemImage: "scope")
                        .foregroundStyle(.red)
                }
                if !grouping.isEmpty {
                    Label("\(grouping.groupedMarkerCount) in \(grouping.clusterCount) groups",
                          systemImage: "circle.grid.2x2.fill")
                }
                if !layers.liveUpdates {
                    Label("paused", systemImage: "pause.fill")
                }
                if model.didDecimate {
                    // Said out loud rather than silently truncated: a partial
                    // harbour that looks complete is worse than a full one.
                    Label("showing the newest \(model.markerBudget)",
                          systemImage: "line.3.horizontal.decrease")
                }
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial)
        }
    }
}

// MARK: - StackedMarkerSheet

/// The members of a group that zooming cannot separate.
///
/// Two systems registered at the same installation point land on the same
/// coordinate exactly, and no zoom level will ever put a gap between them — so
/// this is the only way to reach the one underneath. Deliberately a plain list:
/// the map has already failed to distinguish them, and a second map would fail
/// the same way.
struct StackedMarkerSheet: View {

    let cluster: MarkerClustering.Cluster
    let onSelect: (SystemMapView.Marker) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(cluster.members) { marker in
                Button {
                    onSelect(marker)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: marker.symbol)
                            .foregroundStyle(marker.tint)
                            .frame(width: 24)
                        ActivityDot(state: marker.activity)
                        Text(marker.label ?? marker.id)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.forward")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("\(cluster.count) at this point")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - SystemMarkerSheet

/// What a tapped marker says about its system.
///
/// Cards in the same order as the dashboard — status, then bearing, then the
/// rest — so a KrakenSDR reads "here is the station, here is what it heard"
/// whichever screen it is on.
struct SystemMarkerSheet: View {

    let system: RemoteSystem
    @ObservedObject var model: COPMapModel
    @EnvironmentObject private var connections: NodeConnectionStore
    @EnvironmentObject private var router: TabRouter
    @Environment(\.dismiss) private var dismiss

    /// The source of one target observation, for a summary with no live session
    /// behind it.
    private func targetSource(for observation: ParsedObservation,
                              datastream: RemoteDatastream)
        -> TargetSourceResolver.SourceRef? {
        TargetSourceResolver.source(for: observation,
                                    datastream: datastream,
                                    owner: system,
                                    systems: model.systems,
                                    localDevice: model.localDevice,
                                    position: { model.currentPosition(of: $0) })
    }

    /// Everything a target card needs to name its source and to send the user
    /// to it. The model already holds the whole system list, so this costs
    /// nothing beyond passing it down.
    private var targetContext: TargetCardContext {
        TargetCardContext(systems: model.systems,
                          localDevice: model.localDevice) { source in
            dismiss()
            router.showOnMap(markerId: source.systemId)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        ActivityLabel(activity: model.activity(for: system))
                        Spacer()
                        Text(system.summary.uid ?? system.id)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let session = model.session(for: system.id) {
                        ForEach(DashboardOrder.order(system.datastreams)) { datastream in
                            DatastreamCard(datastream: datastream,
                                           session: session,
                                           targetContext: targetContext)
                        }
                    } else {
                        ForEach(DashboardOrder.order(system.datastreams)) { datastream in
                            let observation = model.newest(systemId: system.id,
                                                           datastreamId: datastream.id)
                            StaticDatastreamSummary(
                                datastream: datastream,
                                observation: observation,
                                targetSource: observation.flatMap {
                                    targetSource(for: $0, datastream: datastream)
                                },
                                onSelectSource: targetContext.onSelectSource)
                        }
                    }

                    if let connection = connections.active {
                        NavigationLink {
                            SystemDashboardView(system: system,
                                                connection: connection,
                                                peers: model.systems)
                        } label: {
                            Label("Open dashboard", systemImage: "square.grid.2x2")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(system.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - StaticDatastreamSummary

/// A datastream with no live session behind it — the Live toggle is off, or the
/// system did not make the subscription cap. Shows the one archived
/// observation, which for a bearing or a settings record is the whole story
/// anyway.
struct StaticDatastreamSummary: View {

    let datastream: RemoteDatastream
    let observation: ParsedObservation?
    /// Resolved by the host, which is the only place that knows the other
    /// systems on the node. Absent for every role but `.target`.
    var targetSource: TargetSourceResolver.SourceRef?
    var onSelectSource: ((TargetSourceResolver.SourceRef) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: SystemGlyph.symbol(for: datastream.role))
                    .foregroundStyle(.secondary)
                Text(datastream.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            if case .target(let paths) = datastream.role, let observation {
                TargetSummaryView(paths: paths,
                                  observation: observation,
                                  source: targetSource,
                                  onSelectSource: onSelectSource)
            } else if case .bearing(let paths) = datastream.role,
               let angle = observation?.values[paths.angle]?.asDouble {
                HStack(alignment: .top, spacing: 12) {
                    HeadingDialView(headingDegrees: angle, needle: .ray, tint: .orange)
                        .frame(width: 80, height: 80)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.1f°", angle))
                            .font(.title3.monospacedDigit().weight(.semibold))
                        if let observation {
                            AsOfLabel(timestamp: observation.phenomenonTime, prominent: true)
                        }
                    }
                    Spacer()
                }
            } else if let record = datastream.recordSchema {
                FieldRowsView(leaves: FieldRowsView.valueLeaves(of: record),
                              latest: observation,
                              showSparklines: false,
                              emptyText: "no archived observation")
                if let observation {
                    AsOfLabel(timestamp: observation.phenomenonTime)
                }
            } else if let schemaError = datastream.schemaError {
                Label(schemaError, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }
}
