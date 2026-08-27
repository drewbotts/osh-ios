import Foundation
import CoreLocation
import Combine

// MARK: - NodeMapModel
//
// Every system on the node that says where it is, on one map.
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
// clearing it after a timeout would delete the only thing on screen.

@MainActor
final class NodeMapModel: ObservableObject {

    // MARK: Configuration

    /// How many systems hold a live subscription at once.
    static let maxLiveSystems = 5

    /// How many markers are drawn before the oldest are dropped.
    ///
    /// SwiftUI's Map has no clustering on this deployment target, so the choice
    /// is decimation or a map that stops responding in a busy anchorage.
    static let maxMarkers = 100

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
    /// True when more entities were found than `maxMarkers`.
    @Published private(set) var didDecimate = false

    @Published var isLive = true {
        didSet { Task { await applyLiveMode() } }
    }

    private let loader = RemoteSystemLoader()
    private var sessions: [String: SystemLiveSession] = [:]
    private var sessionObservers: [String: AnyCancellable] = [:]
    /// systemId → datastreamId → the one archived observation, for static mode.
    private var archived: [String: [String: ParsedObservation]] = [:]

    private var connection: NodeConnection?
    private var refreshTask: Task<Void, Never>?

    /// How often the annotations are rebuilt while streams are running.
    private static let refreshInterval: Duration = .milliseconds(400)

    // MARK: Loading

    func load(connection: NodeConnection?, refresh: Bool = false) async {
        self.connection = connection
        guard let connection else {
            stopAll()
            systems = []
            error = "Select a server on the Node tab first."
            return
        }

        isLoading = true
        defer { isLoading = false }

        if refresh { await loader.invalidate(serverId: connection.server.id) }

        do {
            let summaries = try await connection.readClient.listSystems(limit: 200)
            systems = await loadSystems(summaries, connection: connection, refresh: refresh)
            error = nil
            refreshAnnotations()
            await applyLiveMode()
            refreshAnnotations()
        } catch {
            self.error = error.localizedDescription
            Log.client.error("Node map listing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadSystems(_ summaries: [SystemSummary],
                             connection: NodeConnection,
                             refresh: Bool) async -> [RemoteSystem] {

        let loader = self.loader
        let client = connection.readClient
        let serverId = connection.server.id
        var result: [Int: RemoteSystem] = [:]

        await withTaskGroup(of: (Int, RemoteSystem?).self) { group in
            var next = 0
            func add(_ index: Int) {
                let id = summaries[index].id
                group.addTask {
                    let outcome = await loader.load(systemId: id, using: client,
                                                    serverId: serverId, refresh: refresh)
                    if case .success(let system) = outcome { return (index, system) }
                    return (index, nil)
                }
            }
            while next < summaries.count && next < Self.loadConcurrency {
                add(next); next += 1
            }
            while let (index, system) = await group.next() {
                result[index] = system
                if next < summaries.count { add(next); next += 1 }
            }
        }
        return summaries.indices.compactMap { result[$0] }
    }

    // MARK: Live subscriptions

    /// Opens or closes subscriptions to match the Live toggle.
    private func applyLiveMode() async {
        guard let connection else { return }

        guard isLive else {
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
            let ids = Set(system.datastreams.filter { datastream in
                if case .location = datastream.role { return true }
                if case .bearing = datastream.role { return true }
                return datastream.embeddedPosition != nil
            }.map(\.id))
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

    /// The systems worth subscribing to: those with something that moves,
    /// freshest first, cut at the cap.
    private func liveCandidates() -> [RemoteSystem] {
        systems
            .filter { system in
                system.hasPosition && system.datastreams.contains { datastream in
                    if case .location = datastream.role { return true }
                    if case .bearing = datastream.role { return true }
                    return datastream.embeddedPosition != nil
                }
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
            let relevant = system.datastreams.filter { datastream in
                guard datastream.decoder != nil else { return false }
                if case .location = datastream.role { return true }
                if case .bearing = datastream.role { return true }
                return datastream.embeddedPosition != nil
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
        let built = buildMarkers()
        markers = built.markers
        didDecimate = built.decimated
        bearingLines = buildBearingLines()
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

// MARK: - ISO8601DateFormatter

extension ISO8601DateFormatter {
    /// Parses the node's timestamps whether or not they carry fractional
    /// seconds. One formatter refuses the other's output, and the node emits
    /// both.
    ///
    /// nonisolated(unsafe): formatOptions are set once and never mutated, and
    /// Foundation documents date(from:) as safe for concurrent use.
    nonisolated(unsafe) static let flexible: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: String) -> Date? {
        flexible.date(from: text) ?? plain.date(from: text)
    }
}
