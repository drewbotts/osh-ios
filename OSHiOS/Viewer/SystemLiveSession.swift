import Foundation
import Combine

// MARK: - SystemLiveSession
//
// One system, watched live. The read-side counterpart to SensorSession: where
// that one owns hardware and pushes to a node, this one subscribes to a node
// and publishes to SwiftUI.
//
// Three things make it more than a bag of WebSockets.
//
// Observations from every subscribed datastream pass through one
// TimeSynchronizer before publication, so a video frame and the fix taken at
// the same instant are published together rather than in whatever order the
// node's queues happened to deliver them.
//
// Observations are bucketed by entity, because one AIS datastream carries every
// vessel in range and "the latest observation" is not a position — it is the
// last vessel that happened to transmit.
//
// And not every stream is opened. A dashboard that subscribed to a 1080p camera
// the moment it appeared would saturate the link before the user had read the
// screen, so video waits to be asked for while the low-rate streams that put a
// marker on the map are always included.

@MainActor
final class SystemLiveSession: ObservableObject {

    // MARK: Types

    enum StreamState: Equatable, Sendable {
        case idle
        case connecting
        case streaming
        case disconnected(String?)

        var isLive: Bool {
            switch self {
            case .connecting, .streaming: return true
            case .idle, .disconnected:    return false
            }
        }
    }

    /// Arrival figures for a block (video) stream.
    ///
    /// Kept for H.264 as well as JPEG: Pass 3b decodes no H.264, and these
    /// numbers are the only way a user can tell "not supported yet" from
    /// "not arriving".
    struct BlockStats: Equatable, Sendable {
        var frames = 0
        var lastByteCount = 0
        /// Frames per second over the last two seconds.
        var fps: Double = 0
        var lastArrival: Date?
    }

    // MARK: Published state

    let system: RemoteSystem

    /// Latest observation per datastream, per entity. "" is the bucket for a
    /// single-entity stream.
    @Published private(set) var latest: [String: [String: ParsedObservation]] = [:]

    /// Per-datastream ring of recent observations, entity-agnostic — a
    /// sparkline and a waterfall both want "what has this stream been doing",
    /// not "what has this vessel been doing".
    @Published private(set) var history: [String: [ParsedObservation]] = [:]

    /// Latest decoded frame per video datastream.
    @Published private(set) var frames: [String: DecodedFrame] = [:]

    /// Arrival figures per video datastream, decoded or not.
    @Published private(set) var blockStats: [String: BlockStats] = [:]

    @Published private(set) var streamState: [String: StreamState] = [:]

    /// True once any stream has been asked to open.
    @Published private(set) var isRunning = false

    // MARK: Configuration

    /// How many observations each datastream keeps.
    static let historyLimit = 300

    /// How many sockets one system may hold open.
    static let maxConcurrentStreams = 8

    /// How far back the location and timeseries bootstrap reaches.
    static let bootstrapWindow: TimeInterval = 30 * 60

    /// Reordering window shared by every stream on this system.
    static let synchronizerBufferMillis = 1000

    // MARK: Private state

    private let connection: NodeConnection
    private let synchronizer = TimeSynchronizer(bufferMillis: SystemLiveSession.synchronizerBufferMillis)

    private var streams: [String: ObservationStream] = [:]
    private var consumers: [String: Task<Void, Never>] = [:]
    private var bootstrapTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?

    /// (datastream, entity, millisecond) triples already published, so a
    /// bootstrap page and the live edge overlapping does not double-count.
    private var seen: Set<String> = []

    /// Recent arrival times per block stream, for the rolling fps figure.
    private var blockArrivals: [String: [Date]] = [:]

    // MARK: Init

    init(system: RemoteSystem, connection: NodeConnection) {
        self.system = system
        self.connection = connection
    }

    deinit {
        // Printed rather than logged through OSLog so it survives the
        // deallocation of anything this object owned. "Session for X released"
        // missing from the console after a dashboard is dismissed is the signal
        // that a Task is retaining the session.
        Log.client.info("SystemLiveSession for \(self.system.id, privacy: .public) released")
    }

    // MARK: Lifecycle

    /// Opens streams.
    ///
    /// - Parameter datastreamIds: which to open, or nil for the default set —
    ///   everything but video, capped, most telling first.
    func start(datastreamIds: Set<String>? = nil) {
        let wanted = selection(datastreamIds)
        guard !wanted.isEmpty else { return }

        isRunning = true
        startReleaseLoopIfNeeded()

        for datastream in wanted where streams[datastream.id] == nil {
            open(datastream)
        }

        bootstrapTask?.cancel()
        bootstrapTask = Task { [weak self] in
            await self?.bootstrap(wanted)
        }
    }

    /// Opens one more stream — what a video card's play button calls.
    func start(datastreamId: String) {
        guard let datastream = system.datastreams.first(where: { $0.id == datastreamId }),
              streams[datastreamId] == nil else { return }
        isRunning = true
        startReleaseLoopIfNeeded()
        open(datastream)
        bootstrapTask = Task { [weak self] in
            await self?.bootstrap([datastream])
        }
    }

    /// Closes one stream, leaving the rest alone.
    func stop(datastreamId: String) {
        streams[datastreamId]?.stop()
        streams[datastreamId] = nil
        consumers[datastreamId]?.cancel()
        consumers[datastreamId] = nil
        streamState[datastreamId] = .idle
    }

    /// Closes everything and cancels every task this session started.
    func stop() {
        bootstrapTask?.cancel()
        bootstrapTask = nil

        for (id, stream) in streams {
            stream.stop()
            streamState[id] = .idle
        }
        streams.removeAll()

        for consumer in consumers.values { consumer.cancel() }
        consumers.removeAll()

        releaseTask?.cancel()
        releaseTask = nil

        let synchronizer = self.synchronizer
        Task.detached { await synchronizer.stop() }

        isRunning = false
        Log.client.info("SystemLiveSession for \(self.system.id, privacy: .public) stopped")
    }

    // MARK: Selection

    /// Which datastreams a plain `start()` opens.
    ///
    /// Video is left out because bandwidth is the scarce thing on a phone, and
    /// a camera is the one stream a user can be trusted to ask for. Everything
    /// else is ordered by how much it says about the system — a position or a
    /// line of bearing before a settings dump — and cut at the cap, which is
    /// where a node with forty outputs stops being a denial of service.
    func defaultSelection() -> [RemoteDatastream] {
        let candidates = system.streamsByViewingPriority.filter { datastream in
            guard datastream.decoder != nil else { return false }
            if case .video = datastream.role { return false }
            return true
        }

        if candidates.count > Self.maxConcurrentStreams {
            let dropped = candidates.dropFirst(Self.maxConcurrentStreams).map(\.name)
            Log.client.info("System \(self.system.id, privacy: .public): \(candidates.count) streams exceeds the cap of \(Self.maxConcurrentStreams); not opening \(dropped.joined(separator: ", "), privacy: .public)")
        }
        return Array(candidates.prefix(Self.maxConcurrentStreams))
    }

    private func selection(_ ids: Set<String>?) -> [RemoteDatastream] {
        guard let ids else { return defaultSelection() }
        return system.streamsByViewingPriority
            .filter { ids.contains($0.id) && $0.decoder != nil }
            .prefix(Self.maxConcurrentStreams)
            .map { $0 }
    }

    // MARK: Streaming

    private func open(_ datastream: RemoteDatastream) {
        guard let decoder = datastream.decoder else { return }

        let stream = ObservationStream(connection: connection,
                                       datastreamId: datastream.id,
                                       decoder: decoder)
        streams[datastream.id] = stream
        streamState[datastream.id] = .connecting

        let isVideo: Bool
        if case .video = datastream.role { isVideo = true } else { isVideo = false }
        let compression = datastream.schema?.recordEncoding?.blockCompression

        consumers[datastream.id] = Task { [weak self] in
            for await event in stream.events {
                guard let self else { return }
                await self.handle(event, isVideo: isVideo, compression: compression)
            }
        }

        stream.start()
    }

    private func handle(_ event: ObservationStream.Event,
                        isVideo: Bool,
                        compression: String?) async {
        switch event.kind {
        case .connected:
            streamState[event.datastreamId] = .streaming

        case .disconnected(let error):
            streamState[event.datastreamId] = .disconnected(error?.localizedDescription)

        case .observations(let observations):
            streamState[event.datastreamId] = .streaming
            if isVideo {
                // Frames do not go through the reordering buffer's dictionaries
                // or the history ring: one 300 KB block per observation would
                // hold 300 of them alive per stream.
                for observation in observations {
                    await ingestFrame(observation, compression: compression)
                }
            } else {
                let synchronizer = self.synchronizer
                await synchronizer.add(observations)
            }
        }
    }

    /// Drains the synchronizer onto the main actor.
    ///
    /// One loop for every stream on the system, started once: the whole point
    /// of a shared synchronizer is that it interleaves them, and a loop per
    /// stream would defeat it.
    private func startReleaseLoopIfNeeded() {
        guard releaseTask == nil else { return }
        let synchronizer = self.synchronizer
        releaseTask = Task { [weak self] in
            await synchronizer.start()
            for await observation in synchronizer.observations {
                guard let self else { return }
                await MainActor.run { self.publish(observation) }
            }
        }
    }

    // MARK: Publication

    /// Records one observation, unless it is one already held.
    private func publish(_ observation: ParsedObservation) {
        let datastreamId = observation.datastreamId
        let keyPath = system.datastreams.first { $0.id == datastreamId }?.entityKeyPath
        let entity = EntityKeyInference.entityKey(of: observation, at: keyPath)

        guard admit(observation, datastreamId: datastreamId, entity: entity) else { return }

        ActivityTracker.shared.record(observation,
                                      serverId: connection.server.id,
                                      systemId: system.id)

        latest[datastreamId, default: [:]][entity] = observation

        var ring = history[datastreamId] ?? []
        ring.append(observation)
        if ring.count > Self.historyLimit {
            ring.removeFirst(ring.count - Self.historyLimit)
        }
        history[datastreamId] = ring
    }

    /// Dedupe by phenomenonTime to the millisecond, per datastream and entity.
    ///
    /// The bootstrap and the live edge overlap by design — the fetch covers the
    /// last half hour and the socket starts somewhere inside it — and without
    /// this every sparkline would have a doubled tail.
    private func admit(_ observation: ParsedObservation,
                       datastreamId: String,
                       entity: String) -> Bool {
        let millisecond = Int((observation.phenomenonTime.timeIntervalSince1970 * 1000).rounded())
        let key = "\(datastreamId)|\(entity)|\(millisecond)"
        guard !seen.contains(key) else { return false }
        seen.insert(key)

        // The set would otherwise grow without bound on a stream that runs for
        // an afternoon. Half is dropped at once rather than one per insert so
        // the cost is amortised; the survivors are arbitrary, which is fine —
        // an observation old enough to be forgotten is out of every ring too.
        if seen.count > Self.historyLimit * 8 {
            seen = Set(seen.shuffled().prefix(Self.historyLimit * 4))
        }
        return true
    }

    // MARK: Video

    private func ingestFrame(_ observation: ParsedObservation, compression: String?) async {
        guard let blockValue = observation.values.values.first(where: { value in
            if case .block = value { return true } else { return false }
        }), case .block(let data, let frameCompression) = blockValue else { return }

        let codec = frameCompression ?? compression
        let datastreamId = observation.datastreamId

        recordBlockArrival(datastreamId: datastreamId, byteCount: data.count)
        // Frames skip publish() — see above — so activity is recorded here
        // instead. A camera delivering 15 fps is the most live thing on a node
        // and would otherwise read as offline.
        ActivityTracker.shared.record(datastreamId: datastreamId,
                                      at: observation.phenomenonTime,
                                      serverId: connection.server.id,
                                      systemId: system.id)

        guard MJPEGDecoder.canDecode(compression: codec) else { return }
        if let frame = await MJPEGDecoder.shared.decode(data,
                                                        timestamp: observation.phenomenonTime) {
            frames[datastreamId] = frame
        }
    }

    private func recordBlockArrival(datastreamId: String, byteCount: Int) {
        let now = Date()
        var arrivals = blockArrivals[datastreamId] ?? []
        arrivals.append(now)
        arrivals.removeAll { now.timeIntervalSince($0) > 2 }
        blockArrivals[datastreamId] = arrivals

        var stats = blockStats[datastreamId] ?? BlockStats()
        stats.frames += 1
        stats.lastByteCount = byteCount
        stats.fps = Double(arrivals.count) / 2
        stats.lastArrival = now
        blockStats[datastreamId] = stats
    }

    // MARK: Bootstrap

    /// Fills in what already happened before the socket opened.
    ///
    /// Three shapes, for three reasons. A position or a scalar series is worth
    /// half an hour of context, so a track and a sparkline are not empty for
    /// the first minute. A line of bearing is worth exactly one observation of
    /// any age: KrakenSDR emits only when it detects a signal, so the most
    /// recent LOB may be from Tuesday and is still the thing to show. A stream
    /// that merely reports a position is the same case — one record, however
    /// old, is what puts the marker on the map. So is a target designation:
    /// event-driven, and worth exactly its latest record at any age.
    private func bootstrap(_ datastreams: [RemoteDatastream]) async {
        await withTaskGroup(of: (String, [ParsedObservation]).self) { group in
            for datastream in datastreams {
                guard let decoder = datastream.decoder else { continue }
                guard let plan = Self.bootstrapPlan(for: datastream) else { continue }

                let client = connection.readClient
                let id = datastream.id
                let summary = datastream.summary
                group.addTask {
                    do {
                        let page: (observations: [ParsedObservation], nextURL: URL?)
                        switch plan {
                        case .window(let seconds, let limit):
                            let now = Date()
                            page = try await client.fetchObservations(
                                datastreamId: id,
                                phenomenonTime: now.addingTimeInterval(-seconds)...now,
                                limit: limit,
                                format: ConnectedSystemsReadClient.omJSON,
                                decoder: decoder)
                        case .mostRecent:
                            // Not `latest: true`: a DOA stream that last fired
                            // in June is archive-only, and the node answers
                            // "latest" with nothing at all for those.
                            return (id, try await client.fetchMostRecent(datastream: summary,
                                                                          limit: 1,
                                                                          decoder: decoder))
                        }
                        return (id, page.observations)
                    } catch {
                        Log.client.debug("Bootstrap for datastream \(id, privacy: .public) found nothing: \(error.localizedDescription, privacy: .public)")
                        return (id, [])
                    }
                }
            }

            for await (_, observations) in group {
                guard !Task.isCancelled else { return }
                for observation in observations.sorted(by: { $0.phenomenonTime < $1.phenomenonTime }) {
                    publish(observation)
                }
            }
        }
    }

    private enum BootstrapPlan {
        /// The last `seconds`, up to `limit` records, one page.
        case window(seconds: TimeInterval, limit: Int)
        /// The single most recent record, whatever its age.
        case mostRecent
    }

    private static func bootstrapPlan(for datastream: RemoteDatastream) -> BootstrapPlan? {
        switch datastream.role {
        case .location, .timeseries:
            return .window(seconds: bootstrapWindow, limit: 300)
        case .bearing, .target:
            // A target designation is the same case as a LOB: a range finder
            // fires when someone pulls the trigger, so the last target may be
            // from Tuesday and is still the thing to draw.
            return .mostRecent
        case .video:
            return nil
        default:
            return datastream.embeddedPosition != nil ? .mostRecent : nil
        }
    }

    // MARK: Read-side conveniences

    /// The newest observation on a datastream, across every entity.
    func newest(datastreamId: String) -> ParsedObservation? {
        latest[datastreamId]?.values.max { $0.phenomenonTime < $1.phenomenonTime }
    }

    /// Entities seen on a datastream, newest first.
    func entities(datastreamId: String) -> [(key: String, observation: ParsedObservation)] {
        (latest[datastreamId] ?? [:])
            .map { (key: $0.key, observation: $0.value) }
            .sorted { $0.observation.phenomenonTime > $1.observation.phenomenonTime }
    }

    /// How many streams are open, and how many are not.
    var stateSummary: (live: Int, idle: Int) {
        let live = streamState.values.filter(\.isLive).count
        return (live, streamState.count - live)
    }
}
