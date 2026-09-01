import Foundation
import CoreLocation
import Combine

// MARK: - COPMapModel
//
// Every system on the node that says where it is, on one map — the node half of
// the common operating picture. This device's own track and fix are added by
// the view, from SensorSession, so the phone keeps drawing itself whether or
// not a node is configured, reachable or interesting.
//
// Three things are genuinely hard here and all three are about restraint.
//
// A node can hold a dozen systems and an AIS receiver alone can carry a hundred
// vessels, so only a handful of systems get a live subscription — the ones with
// the freshest data — and everything else is a single archived observation.
//
// A system's position can come from three places and they are not equal: a live
// fix beats a position a settings record mentions, which beats the point in the
// system's own registration. PositionKind carries which, and the marker looks
// different for each, because "we are tracking this" and "someone typed this in
// once" should not read the same.
//
// And a line of bearing is never removed. Direction finding emits only on
// detection; a LOB from an hour ago is the answer to "which way was it", and
// clearing it after a timeout would delete the only thing on screen. A target
// designation is the same kind of event and keeps the same rule.

@MainActor
final class COPMapModel: ObservableObject {

    // MARK: Configuration

    /// How many systems hold a live subscription at once.
    static let maxLiveSystems = 5

    /// How many markers are built before the oldest are dropped, with grouping
    /// switched off.
    ///
    /// Decimation is the last resort and it is a lie by omission: the hundred
    /// newest vessels in a busy anchorage look exactly like all of them. It is
    /// kept only for the ungrouped case, where every marker really is its own
    /// annotation and the map stops responding somewhere above this.
    static let maxMarkers = 100

    /// The budget when markers are grouped.
    ///
    /// Four times higher because clustering breaks the link between markers
    /// held and annotations drawn: a thousand vessels in one anchorage become a
    /// handful of bubbles, and the only per-marker cost left is the clustering
    /// pass itself, which is one comparison each.
    static let maxClusteredMarkers = 400

    /// Systems loaded at once when the tab appears.
    static let loadConcurrency = 4

    // MARK: State

    @Published private(set) var systems: [RemoteSystem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    /// The drawn annotations, recomputed on a coalescing timer rather than in
    /// the view's body: a 10 Hz AIS stream would otherwise rebuild a hundred
    /// markers on every observation, for a map nobody can read at that rate.
    @Published private(set) var markers: [SystemMapView.Marker] = []
    @Published private(set) var bearingLines: [SystemMapView.BearingLine] = []
    /// One line per designated target, from its source's *current* position.
    @Published private(set) var targetLines: [SystemMapView.TargetLine] = []
    /// Past targets, built only while the history layer is on.
    @Published private(set) var targetHistory: [SystemMapView.TargetDot] = []
    /// True when more entities were found than `maxMarkers`.
    @Published private(set) var didDecimate = false

    /// Freshness snapshot, refreshed when the tracker publishes.
    ///
    /// Copied into the model rather than read by each marker: a hundred
    /// annotations each observing the tracker would redraw the whole map
    /// whenever any one system changed colour.
    private var activityStates: [String: ActivityState] = [:]

    /// Which layers to draw. The view keeps this in step with AppConfig.
    @Published var layers = MapLayers() {
        didSet {
            guard oldValue != layers else { return }
            if oldValue.liveUpdates != layers.liveUpdates {
                Task { await applyLiveMode() }
            } else {
                refreshAnnotations()
            }
        }
    }

    /// This device as a source candidate. Supplied by the view, which is what
    /// owns the sensor session, and refreshed as the phone moves.
    private(set) var localDevice: TargetSourceResolver.LocalDeviceRef?

    /// (datastream, source) pairs already reported as unlocatable, so a target
    /// whose observer nothing can place says so once rather than at 2.5 Hz.
    private var loggedSourcelessTargets: Set<String> = []

    private let loader = RemoteSystemLoader()
    private var activityObserver: AnyCancellable?
    private var sessions: [String: SystemLiveSession] = [:]
    private var sessionObservers: [String: AnyCancellable] = [:]
    /// systemId → datastreamId → the one archived observation, for static mode.
    private var archived: [String: [String: ParsedObservation]] = [:]

    private var connection: NodeConnection?
    private var refreshTask: Task<Void, Never>?

    /// How often the annotations are rebuilt while streams are running.
    private static let refreshInterval: Duration = .milliseconds(400)

    // MARK: This device

    /// Tells the model where this device is, for target lines whose source is
    /// the phone itself. A no-op when nothing changed, so the caller can pass
    /// it on every fix.
    func setLocalDevice(_ device: TargetSourceResolver.LocalDeviceRef?) {
        guard device != localDevice else { return }
        localDevice = device
        scheduleRefresh()
    }

    // MARK: Loading

    func load(connection: NodeConnection?, refresh: Bool = false) async {
        self.connection = connection
        guard let connection else {
            stopAll()
            systems = []
            error = "Select a server on the Systems tab first."
            return
        }

        isLoading = true
        defer { isLoading = false }

        if refresh { await loader.invalidate(serverId: connection.server.id) }

        observeActivity()

        do {
            let summaries = try await connection.readClient.listSystems(limit: 200)
            systems = await loader.loadAll(summaries,
                                           using: connection.readClient,
                                           serverId: connection.server.id,
                                           refresh: refresh,
                                           concurrency: Self.loadConcurrency)
            error = nil
            seedActivity(serverId: connection.server.id)
            refreshAnnotations()
            await applyLiveMode()
            refreshAnnotations()
        } catch {
            self.error = error.localizedDescription
            Log.client.error("Node map listing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Activity

    /// Seeds the tracker from what the node reported at load, so a system that
    /// is not subscribed still shows an honest colour.
    private func seedActivity(serverId: UUID) {
        for system in systems {
            ActivityTracker.shared.seed(system.activity,
                                        serverId: serverId,
                                        systemId: system.id)
        }
        captureActivity(serverId: serverId)
    }

    /// Follows the tracker so a system decaying to amber redraws its marker.
    ///
    /// The tracker publishes only on a genuine state change or on its 30 s
    /// re-evaluation, so this is a handful of refreshes a minute rather than
    /// one per observation.
    private func observeActivity() {
        guard activityObserver == nil else { return }
        activityObserver = ActivityTracker.shared.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
    }

    private func captureActivity(serverId: UUID) {
        var states: [String: ActivityState] = [:]
        for system in systems {
            states[system.id] = ActivityTracker.shared.state(serverId: serverId,
                                                             systemId: system.id)
        }
        activityStates = states
    }

    /// How many markers may be built before the oldest are dropped.
    var markerBudget: Int {
        layers.clusterMarkers ? Self.maxClusteredMarkers : Self.maxMarkers
    }

    /// Freshness of one system, for its marker.
    func activityState(_ systemId: String) -> ActivityState {
        activityStates[systemId] ?? .offline
    }

    /// The full activity of one system, for a sheet or a detail row.
    func activity(for system: RemoteSystem) -> SystemActivity {
        guard let serverId = connection?.server.id else { return system.activity }
        return ActivityTracker.shared.activity(serverId: serverId, systemId: system.id)
    }

    // MARK: Live subscriptions

    /// Opens or closes subscriptions to match the Live toggle.
    private func applyLiveMode() async {
        guard let connection else { return }

        guard layers.liveUpdates else {
            stopAll()
            await fetchArchivedPositions(connection: connection)
            refreshAnnotations()
            return
        }

        let wanted = Set(liveCandidates().map(\.id))

        for id in sessions.keys where !wanted.contains(id) {
            sessions[id]?.stop()
            sessions[id] = nil
            sessionObservers[id] = nil
        }

        for system in liveCandidates() where sessions[system.id] == nil {
            let session = SystemLiveSession(system: system, connection: connection)
            // Only the streams that move a marker or draw a line. A dashboard
            // opens everything; a map has no use for a settings dump beyond the
            // position inside it, and none at all for a spectrum.
            let ids = Set(system.datastreams.filter(Self.drawsOnMap).map(\.id))
            guard !ids.isEmpty else { continue }

            sessions[system.id] = session
            sessionObservers[system.id] = session.objectWillChange
                .sink { [weak self] _ in self?.scheduleRefresh() }
            session.start(datastreamIds: ids)
        }

        // Systems without a live session still need their last known position.
        await fetchArchivedPositions(connection: connection,
                                     excluding: Set(sessions.keys))
        refreshAnnotations()
    }

    /// Whether a datastream puts anything on the map.
    ///
    /// One predicate rather than three copies: it decides which streams get a
    /// subscription, which get an archived fetch, and — by omission — which a
    /// map has no use for. A settings dump qualifies only for the position
    /// inside it; a spectrum never does.
    static func drawsOnMap(_ datastream: RemoteDatastream) -> Bool {
        switch datastream.role {
        case .location, .bearing, .target: return true
        default:                            return datastream.embeddedPosition != nil
        }
    }

    /// The systems worth subscribing to: those with something that moves,
    /// freshest first, cut at the cap.
    private func liveCandidates() -> [RemoteSystem] {
        systems
            .filter { system in
                guard system.datastreams.contains(where: Self.drawsOnMap) else { return false }
                // A range finder has no position of its own and still belongs
                // on the map: what it draws is out where it was pointing.
                return system.hasPosition || !system.targetDatastreams.isEmpty
            }
            .sorted { Self.freshness($0) > Self.freshness($1) }
            .prefix(Self.maxLiveSystems)
            .map { $0 }
    }

    /// The most recent phenomenonTime any of a system's datastreams reports.
    ///
    /// "now" as the upper bound means the node considers the stream open, which
    /// is the freshest a datastream can claim to be.
    static func freshness(_ system: RemoteSystem) -> Date {
        system.datastreams
            .compactMap { $0.summary.phenomenonTimeRange?.last }
            .map { bound -> Date in
                if bound.caseInsensitiveCompare("now") == .orderedSame { return .distantFuture }
                return ISO8601DateFormatter.parse(bound) ?? .distantPast
            }
            .max() ?? .distantPast
    }

    /// One archived observation per position-bearing datastream, for systems
    /// with no live session.
    private func fetchArchivedPositions(connection: NodeConnection,
                                        excluding live: Set<String> = []) async {
        let client = connection.readClient

        for system in systems where !live.contains(system.id) {
            let relevant = system.datastreams.filter {
                $0.decoder != nil && Self.drawsOnMap($0)
            }
            guard !relevant.isEmpty else { continue }

            for datastream in relevant {
                guard archived[system.id]?[datastream.id] == nil,
                      let decoder = datastream.decoder else { continue }
                // The newest record however old it is: a station that last
                // heard something in June still belongs on the map, pointing
                // where it was pointing.
                let observations = try? await client.fetchMostRecent(
                    datastream: datastream.summary, limit: 1, decoder: decoder)
                if let observation = observations?.first {
                    archived[system.id, default: [:]][datastream.id] = observation
                }
            }
        }
    }

    func stopAll() {
        refreshTask?.cancel()
        refreshTask = nil
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        sessionObservers.removeAll()
    }

    // MARK: Annotation refresh

    /// Rebuilds the annotations soon, and at most once per interval.
    ///
    /// Deferred rather than immediate because `objectWillChange` fires *before*
    /// the session has stored the new observation; reading it now would draw
    /// the previous frame's positions forever.
    func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: Self.refreshInterval)
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            self.refreshAnnotations()
        }
    }

    func refreshAnnotations() {
        if let serverId = connection?.server.id { captureActivity(serverId: serverId) }
        let built = buildMarkers()
        markers = built.markers
        didDecimate = built.decimated
        bearingLines = buildBearingLines()
        let targets = buildTargetOverlays()
        targetLines = targets.lines
        targetHistory = targets.history
    }

    // MARK: Target sources

    /// Where a node system is *now*, for a target line's origin.
    ///
    /// Deliberately the same answer the system's own marker gets — live beats
    /// reported beats deployed, via `PositionKind` — so a line always starts
    /// exactly where the source is drawn, and follows it when it moves.
    func currentPosition(of system: RemoteSystem) -> CLLocationCoordinate2D? {
        markers(for: system).first?.coordinate
    }

    /// Says once, at debug, that a target's observer could not be placed.
    func noteSourceWithoutPosition(datastreamId: String,
                                   source: TargetSourceResolver.SourceRef) {
        let key = "\(datastreamId)|\(source.systemId)"
        guard !loggedSourcelessTargets.contains(key) else { return }
        loggedSourcelessTargets.insert(key)
        Log.client.debug("Target stream \(datastreamId, privacy: .public): source \(source.name, privacy: .public) (\(source.resolution.rawValue, privacy: .public)) has no position; drawing the target marker only")
    }

    // MARK: Reading

    func session(for systemId: String) -> SystemLiveSession? { sessions[systemId] }

    /// Every observation currently known for one datastream, per entity.
    private func observations(systemId: String, datastreamId: String)
        -> [(key: String, observation: ParsedObservation)] {
        if let session = sessions[systemId] {
            let live = session.entities(datastreamId: datastreamId)
            if !live.isEmpty { return live }
        }
        if let single = archived[systemId]?[datastreamId] {
            return [(key: "", observation: single)]
        }
        return []
    }

    func newest(systemId: String, datastreamId: String) -> ParsedObservation? {
        observations(systemId: systemId, datastreamId: datastreamId)
            .max { $0.observation.phenomenonTime < $1.observation.phenomenonTime }?
            .observation
    }
}
