import SwiftUI

// MARK: - SystemDashboardView
//
// Everything one system is doing, right now, in one screen.
//
// The grid is built from roles, not from a layout someone wrote for a
// particular node: a KrakenSDR gets a settings card, a bearing dial and a
// waterfall because that is what its three datastreams are, and a system nobody
// has ever connected before gets whatever its schemas turn out to describe.
//
// The session starts on appear and stops on disappear. That is not tidiness —
// a dashboard left subscribed in the navigation stack behind three other
// screens would hold eight WebSockets open on a phone.

struct SystemDashboardView: View {

    let system: RemoteSystem
    let connection: NodeConnection
    /// The other systems on this node, as the host already had them.
    ///
    /// Only a `.target` card reads them, and only to name the system a target
    /// was observed from — a range finder's record says where the target is and
    /// nothing about who was holding it. Empty is fine; the card then falls
    /// back to this system.
    let peers: [RemoteSystem]

    @EnvironmentObject private var connections: NodeConnectionStore
    @EnvironmentObject private var router: TabRouter
    @StateObject private var session: SystemLiveSession

    @State private var expandedMapDatastream: RemoteDatastream?

    init(system: RemoteSystem, connection: NodeConnection, peers: [RemoteSystem] = []) {
        self.system = system
        self.connection = connection
        self.peers = peers
        _session = StateObject(wrappedValue: SystemLiveSession(system: system,
                                                               connection: connection))
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                // Controls first. A camera you can move is a camera you came
                // to this screen to move, and burying the D-pad under nine
                // observation cards would make the one interactive thing on
                // the dashboard the hardest to find.
                ForEach(system.controlStreams) { controlStream in
                    ControlStreamCard(controlStream: controlStream,
                                      connection: connection)
                }
                ForEach(orderedDatastreams) { datastream in
                    DatastreamCard(datastream: datastream,
                                   session: session,
                                   onExpandMap: { expandedMapDatastream = $0 },
                                   targetContext: targetContext)
                }
            }
            .padding(12)

            footer
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(system.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear { session.start() }
        .onDisappear { session.stop() }
        .sheet(item: $expandedMapDatastream) { datastream in
            ExpandedMapSheet(datastream: datastream, session: session)
        }
    }

    /// Status first, then bearing, then everything else in viewing order.
    ///
    /// A direction-finding station reads top-down as "here is the station, here
    /// is what it heard": the settings card carries the position and the array
    /// heading, and the LOB dial is meaningless without them.
    private var orderedDatastreams: [RemoteDatastream] {
        DashboardOrder.order(system.datastreams)
    }

    private var targetContext: TargetCardContext {
        TargetCardContext(systems: peers) { source in
            router.showOnMap(markerId: source.systemId)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            let summary = session.stateSummary
            Text("\(summary.live) live / \(summary.idle) idle")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(session.isRunning ? "Stop all" : "Start",
                   systemImage: session.isRunning ? "stop.fill" : "play.fill") {
                session.isRunning ? session.stop() : session.start()
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !system.subsystems.isEmpty {
                Text("\(system.subsystems.count) subsystems")
            }
            if system.controlStreamCount > 0 {
                Label(system.ptzCapability != nil
                        ? "\(system.controlStreamCount) control streams, one of them PTZ"
                        : "\(system.controlStreamCount) control streams",
                      systemImage: "slider.horizontal.3")
            }
            if let kind = system.positionKind {
                Label(positionDescription(kind), systemImage: "mappin.and.ellipse")
            }
            Text(system.summary.uid ?? system.id)
                .font(.caption2.monospaced())
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 20)
    }

    private func positionDescription(_ kind: RemoteSystem.PositionKind) -> String {
        switch kind {
        case .live:     return "position from a live datastream"
        case .reported: return "position reported by a datastream"
        case .deployed: return "position from the system record"
        }
    }
}

// MARK: - DashboardOrder

/// Card order, shared by the dashboard and the map's marker sheet so the same
/// system reads the same way in both.
enum DashboardOrder {

    static func order(_ datastreams: [RemoteDatastream]) -> [RemoteDatastream] {
        datastreams.enumerated().sorted { left, right in
            let leftRank = rank(left.element.role)
            let rightRank = rank(right.element.role)
            if leftRank != rightRank { return leftRank < rightRank }
            return left.offset < right.offset
        }.map(\.element)
    }

    private static func rank(_ role: DatastreamRole) -> Int {
        switch role {
        case .status:  return 0
        case .bearing: return 1
        default:       return 2
        }
    }
}

// MARK: - ExpandedMapSheet

/// A location card's map, full screen, with its controls back.
private struct ExpandedMapSheet: View {

    let datastream: RemoteDatastream
    @ObservedObject var session: SystemLiveSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if case .location(let paths, let headingPath) = datastream.role {
                    let entities = session.entities(datastreamId: datastream.id)
                    SystemMapView(
                        markers: LocationCardModel.markers(
                            entities: entities,
                            paths: paths,
                            headingPath: headingPath,
                            symbol: SystemGlyph.symbol(for: datastream.role),
                            fallbackId: datastream.id),
                        tracks: datastream.entityKeyPath == nil
                            ? [LocationCardModel.track(session.history[datastream.id] ?? [],
                                                       paths: paths)].filter { $0.count >= 2 }
                            : [])
                } else {
                    ContentUnavailableView("Not a location stream",
                                           systemImage: "mappin.slash")
                }
            }
            .navigationTitle(datastream.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
