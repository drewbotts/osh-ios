import Foundation
import Combine
import AVFoundation

// MARK: - SessionError

enum SessionError: Error, LocalizedError {
    case unexpectedExit

    var errorDescription: String? { "The session ended unexpectedly" }
}

// MARK: - SensorSession
//
// Owns the full lifecycle for one streaming run.
//
// State machine:
//   idle       → connecting    (start() called)
//   connecting → streaming     (all registration steps succeeded)
//   connecting → failed(Error) (any step threw, or task cancelled by non-user path)
//   streaming  → idle          (stop() called)
//   failed     → connecting    (start() called again — Retry)
//   failed     → idle          (dismissError() called)
//
// CRITICAL: every exit from .connecting MUST transition to .streaming or .failed.
// The defer block in run() is the safety net that enforces this.
//
// Live readings are published as SensorLiveState, one per output, keyed by
// output name. Each carries the output's schema and its observations already
// parsed onto that schema, so the UI never needs to know which sensor class
// produced them — the same views will render datastreams read back from a node.

@MainActor
final class SensorSession: ObservableObject {

    // MARK: - State

    enum State {
        case idle
        case connecting(String)  // step description shown in UI
        case streaming
        case failed(Error)       // startup failed; Retry or Dismiss
    }

    @Published private(set) var state: State = .idle

    /// Live readings per output name. Use `sensorList` for display order.
    @Published private(set) var sensors: [String: SensorLiveState] = [:]

    /// False while streaming if the network path or the OSH node is unavailable
    /// (observations are buffering in ObservationPublisher's ring buffer).
    @Published private(set) var isNetworkConnected = true
    /// Observations successfully accepted by the server this session.
    @Published private(set) var sentCount = 0
    /// Failed POST batches this session.
    @Published private(set) var errorCount = 0
    /// Observations waiting in the publisher's batches and ring buffer.
    @Published private(set) var queuedCount = 0

    /// Set when the state becomes .streaming; drives the elapsed-time readout.
    @Published private(set) var sessionStart: Date?

    /// Latest encoder telemetry, or nil when video is not running.
    @Published private(set) var videoStats: VideoStats?

    /// Horizontal accuracy of the most recent GPS fix, in metres.
    @Published private(set) var gpsAccuracy: Double?

    /// Positions recorded this session, oldest first. Capped at `trackCapacity`;
    /// past that the track is decimated rather than truncated, so a long run
    /// still shows its whole shape instead of only its most recent stretch.
    @Published private(set) var gpsTrack: [TrackPoint] = []

    /// Maximum points retained in `gpsTrack`.
    static let trackCapacity = 5_000

    /// The newest position, or nil before the first fix.
    var currentFix: TrackPoint? { gpsTrack.last }

    /// Outputs in the order the session built them.
    var sensorList: [SensorLiveState] {
        sensorOrder.compactMap { sensors[$0] }
    }

    // MARK: - Private

    private var modules: [SensorModule] = []
    private var sensorOrder: [String] = []
    /// Schema and encoding per output name, used to parse incoming observations.
    private var parseInfo: [String: (schema: DataRecord, encoding: BinaryEncoding)] = [:]

    /// Output name and coordinate paths of the first location-bearing schema
    /// in this run — the source of `gpsTrack`.
    private var trackSourceName: String?
    private var trackPaths: LocationPaths?

    private var orientCoord: OrientationOutputCoordinator?
    private var client: ConnectedSystemsClient?
    private var publisher: ObservationPublisher?
    private var cancellables = Set<AnyCancellable>()
    private var runTask: Task<Void, Never>?
    /// Mirrors ObservationPublisher's status stream into the @Published properties above.
    private var statusTask: Task<Void, Never>?
    /// Mirrors VideoOutput's telemetry stream.
    private var videoStatsTask: Task<Void, Never>?
    /// Mirrors GPSOutput's accuracy side channel.
    private var gpsAccuracyTask: Task<Void, Never>?
    /// 1 s tick that ages readings out to .stale and refreshes obs/s.
    private var tickTask: Task<Void, Never>?

    /// Live Activity for the Lock Screen and Dynamic Island.
    private let liveActivity = SessionActivityController()

    // MARK: - Public API

    /// Begin a new session. Allowed from .idle or .failed (retry path).
    ///
    /// The connection supplies both the client and the server identity: cached
    /// registration ids are scoped per server, because each OSH node mints its
    /// own resource ids and reusing one across nodes produces 404 churn.
    func start(config: AppConfig, connection: NodeConnection, systemName: String) {
        switch state {
        case .idle, .failed: break
        default: return  // already connecting or streaming
        }
        resetLiveState()
        runTask = Task { await run(config: config, connection: connection, systemName: systemName) }
    }

    /// Stop an active streaming session and return to .idle.
    func stop() {
        runTask?.cancel()
        runTask = nil
        cleanupModules()
        resetLiveState()
        state = .idle
    }

    /// Cancel a startup that is currently .connecting and return to .idle.
    func cancelStartup() {
        guard case .connecting = state else { return }
        stop()
    }

    /// Discards the recorded track without affecting the session.
    func clearTrack() {
        gpsTrack.removeAll()
    }

    /// Dismiss the .failed state and return to .idle without retrying.
    func dismissError() {
        guard case .failed = state else { return }
        state = .idle
    }

    /// Whether the session is active (connecting or streaming) — use to disable UI controls.
    var isActive: Bool {
        switch state {
        case .connecting, .streaming: return true
        default: return false
        }
    }

    /// The capture session backing the camera preview, or nil when video is not
    /// part of this run. Handed to the Camera tab's preview layer.
    var videoCaptureSession: AVCaptureSession? {
        modules.compactMap { $0 as? VideoOutput }.first?.captureSession
    }

    // MARK: - Run loop

    private func run(config: AppConfig, connection: NodeConnection, systemName: String) async {
        let server = connection.server

        // Safety net: if we exit this function while still .connecting for any reason
        // (unhandled throw, programming error), transition to .failed so the UI never sticks.
        var succeeded = false
        defer {
            if !succeeded {
                cleanupModules()
                // Only set .failed if we weren't cancelled — stop() already set .idle.
                if !Task.isCancelled, case .connecting = state {
                    state = .failed(SessionError.unexpectedExit)
                }
            }
        }

        do {
            // ── Step 1: Build sensor modules ─────────────────────────────────
            try advance(to: "Building sensor modules…")
            let descriptor = SystemDescriptor(systemName: systemName)

            var builtModules: [SensorModule] = []

            if config.enableGPS {
                builtModules.append(GPSOutput(localFrameURI: descriptor.localFrameURI))
            }

            let coord = OrientationOutputCoordinator(localFrameURI: descriptor.localFrameURI,
                                                     updateInterval: config.orientationInterval)
            if config.enableOrientationQuat  { builtModules.append(coord.quatOutput) }
            if config.enableOrientationEuler { builtModules.append(coord.eulerOutput) }
            let needsOrientation = config.enableOrientationQuat || config.enableOrientationEuler
            if needsOrientation { self.orientCoord = coord }

            if config.enableBarometer  { builtModules.append(BarometerOutput()) }
            if config.enableAudioLevel { builtModules.append(AudioLevelOutput(samplingPeriod: config.audioInterval)) }
            if config.enableVideoH264  { builtModules.append(VideoOutputH264(config: config.videoConfig)) }

            self.modules = builtModules
            self.sensorOrder = builtModules.map(\.outputName)

            // ── Step 2: Take the node's write client ──────────────────────────
            try advance(to: "Connecting to \(server.url)…")
            let client = connection.writeClient
            self.client = client

            // ── Step 3: Register system ───────────────────────────────────────
            try advance(to: "Registering system…")
            let systemId = try await SystemRegistration.registerIfNeeded(
                client: client,
                serverId: server.id,
                descriptor: descriptor
            )

            // ── Step 4: Configure hardware ────────────────────────────────────
            //
            // configure() is what gives video its real dimensions, so the live
            // states are built from the schemas only after it has run.
            try advance(to: "Configuring sensors…")
            var unavailableReasons: [String: String] = [:]
            var configuredModules: [SensorModule] = []
            for module in builtModules {
                do {
                    try module.configure()
                    configuredModules.append(module)
                } catch SensorError.unavailable(let msg) {
                    unavailableReasons[module.outputName] = msg
                }
                // Non-unavailable errors propagate to the outer catch → .failed
            }
            buildLiveStates(from: builtModules, unavailable: unavailableReasons)
            builtModules = configuredModules

            // ── Step 5: Register datastreams ──────────────────────────────────
            try advance(to: "Registering datastreams…")
            var datastreamIds: [String: String] = [:]
            for module in builtModules {
                let dsId = try await DatastreamRegistration.registerIfNeeded(
                    client: client,
                    serverId: server.id,
                    systemId: systemId,
                    outputName: module.outputName,
                    schema: module.recordDescription,
                    encoding: module.recommendedEncoding
                )
                datastreamIds[module.outputName] = dsId
            }

            // ── Step 6: Wire ObservationPublisher ─────────────────────────────
            var datastreamSchemas: [String: DataRecord] = [:]
            for module in builtModules {
                datastreamSchemas[module.outputName] = module.recordDescription
            }

            let pub = ObservationPublisher()
            await pub.configure(client: client, systemId: systemId,
                                datastreamIds: datastreamIds,
                                datastreamSchemas: datastreamSchemas)
            // Scalar sensors only — pub skips binary-block modules, and video is
            // wired to its own direct-post path below.
            await pub.subscribe(to: builtModules)
            await pub.startNetworkMonitoring()
            self.publisher = pub

            // Video bypasses ObservationPublisher entirely: frames go straight to
            // the server so a multi-hundred-KB payload never enters the scalar
            // ring buffer or batch array. Its delivery counters therefore come
            // from here rather than from the publisher's status stream.
            for module in builtModules {
                guard let video = module as? VideoOutput,
                      let dsId = datastreamIds[video.outputName] else { continue }
                let schema = video.recordDescription
                let name = video.outputName
                video.directPoster = { [weak self] observation in
                    do {
                        let bytes = try await client.postObservation(datastreamId: dsId,
                                                                     observation: observation,
                                                                     schema: schema)
                        await self?.recordVideoPost(outputName: name, bytes: bytes, failed: false)
                    } catch {
                        Log.video.error("Frame POST failed: \(error.localizedDescription, privacy: .public)")
                        await self?.recordVideoPost(outputName: name, bytes: 0, failed: true)
                    }
                }
            }

            // Mirror publisher health into @Published state for the UI.
            // Task inherits this @MainActor isolation, so the assignments are safe.
            let statusStream = await pub.status
            statusTask = Task { [weak self] in
                for await status in statusStream {
                    guard let self else { return }
                    self.apply(status)
                }
            }

            // ── Step 7: Start sensors ─────────────────────────────────────────
            try advance(to: "Starting sensors…")

            if needsOrientation {
                do {
                    try coord.start()
                } catch SensorError.unavailable(let msg) {
                    markUnavailable(outputNames: [coord.quatOutput.outputName,
                                                  coord.eulerOutput.outputName],
                                    reason: msg)
                    builtModules.removeAll { $0 is QuatOrientationOutput || $0 is EulerOrientationOutput }
                    self.orientCoord = nil
                }
                // Non-unavailable errors propagate to outer catch → .failed
            }

            for module in builtModules {
                guard !(module is QuatOrientationOutput),
                      !(module is EulerOrientationOutput) else { continue }
                do {
                    try module.start()
                } catch SensorError.unavailable(let msg) {
                    markUnavailable(outputNames: [module.outputName], reason: msg)
                    builtModules.removeAll { $0.outputName == module.outputName }
                }
                // Non-unavailable errors propagate to outer catch → .failed
            }

            for module in builtModules {
                subscribeObservations(for: module)
            }
            subscribeSideChannels(of: builtModules)

            // ── Done ──────────────────────────────────────────────────────────
            succeeded = true
            sessionStart = Date()
            state = .streaming
            startStaleTicker()
            liveActivity.start(systemName: systemName,
                               sensorCount: builtModules.count,
                               startedAt: sessionStart ?? Date())

        } catch {
            // Single exit point for all failures.
            // If the task was cancelled, stop() already set state = .idle — leave it.
            if !Task.isCancelled {
                state = .failed(error)
            }
            liveActivity.end()
            // defer handles cleanupModules()
        }
    }

    /// Checks for task cancellation, then advances the connecting status message.
    /// Throws CancellationError if the task was cancelled, unwinding the run() do/catch.
    private func advance(to message: String) throws {
        try Task.checkCancellation()
        state = .connecting(message)
    }

    // MARK: - Cleanup

    private func cleanupModules() {
        cancellables.removeAll()
        statusTask?.cancel()
        statusTask = nil
        videoStatsTask?.cancel()
        videoStatsTask = nil
        gpsAccuracyTask?.cancel()
        gpsAccuracyTask = nil
        tickTask?.cancel()
        tickTask = nil
        liveActivity.end()
        // stopAll() is actor-isolated; hand the publisher to a detached hop so
        // cleanup stays synchronous for the defer in run() and for stop().
        if let pub = publisher {
            Task { await pub.stopAll() }
        }
        for module in modules {
            (module as? VideoOutput)?.directPoster = nil
            module.stop()
        }
        orientCoord?.stop()
        modules      = []
        orientCoord  = nil
        client       = nil
        publisher    = nil
    }

    /// Clears everything a run publishes, without touching `state`.
    private func resetLiveState() {
        sensors = [:]
        sensorOrder = []
        parseInfo = [:]
        isNetworkConnected = true
        sentCount = 0
        errorCount = 0
        queuedCount = 0
        sessionStart = nil
        videoStats = nil
        gpsAccuracy = nil
        gpsTrack = []
        trackSourceName = nil
        trackPaths = nil
    }

    // MARK: - Live state

    /// Builds one SensorLiveState per output, in build order. Outputs whose
    /// hardware refused to configure are kept in the list and marked
    /// unavailable — a missing card would look like the sensor was never asked
    /// for, which is a different thing entirely.
    private func buildLiveStates(from modules: [SensorModule],
                                 unavailable: [String: String]) {
        var states: [String: SensorLiveState] = [:]
        for module in modules {
            let schema = module.recordDescription
            var state = SensorLiveState(id: module.outputName,
                                        displayName: schema.label ?? module.outputName,
                                        schema: schema)
            if let reason = unavailable[module.outputName] {
                state.markUnavailable(reason)
                Log.session.info("\(module.outputName, privacy: .public) unavailable: \(reason, privacy: .public)")
            }
            states[module.outputName] = state
            parseInfo[module.outputName] = (schema, module.recommendedEncoding)

            if trackSourceName == nil, let paths = LocationPaths.resolve(in: schema) {
                trackSourceName = module.outputName
                trackPaths = paths
            }
        }
        sensors = states
    }

    private func markUnavailable(outputNames: [String], reason: String) {
        for name in outputNames {
            sensors[name]?.markUnavailable(reason)
            Log.session.info("\(name, privacy: .public) unavailable: \(reason, privacy: .public)")
        }
    }

    /// Applies one publisher health snapshot to the published counters.
    private func apply(_ status: ObservationPublisher.Status) {
        isNetworkConnected = status.isConnected
        sentCount   = status.sentCount
        errorCount  = status.errorCount
        queuedCount = status.queuedCount

        for (name, counters) in status.perDatastream {
            sensors[name]?.stats.observations = counters.sent
            sensors[name]?.stats.bytes        = counters.bytes
            sensors[name]?.stats.errors       = counters.errors
        }
        liveActivity.update(isConnected: status.isConnected)
    }

    /// Video's counters come from its own POST path, not the publisher's.
    private func recordVideoPost(outputName: String, bytes: Int, failed: Bool) {
        guard var state = sensors[outputName] else { return }
        if failed {
            state.stats.errors += 1
        } else {
            state.stats.observations += 1
            state.stats.bytes += bytes
        }
        sensors[outputName] = state
    }

    // MARK: - Live subscriptions

    /// Parses every observation from one module onto its schema and files it
    /// under the module's output name.
    private func subscribeObservations(for module: SensorModule) {
        guard let info = parseInfo[module.outputName] else { return }
        let name = module.outputName
        module.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] observation in
                guard let self else { return }
                do {
                    let parsed = try observation.parsed(schema: info.schema,
                                                        encoding: info.encoding)
                    self.sensors[name]?.append(parsed)
                    if name == self.trackSourceName { self.appendTrackPoint(from: parsed) }
                } catch {
                    // A mismatch means the module's value array and its schema
                    // have drifted apart — a programming error, not a runtime
                    // condition, so it is logged rather than surfaced.
                    Log.session.error("Cannot parse \(name, privacy: .public) observation: \(error.localizedDescription, privacy: .public)")
                }
            }
            .store(in: &cancellables)
    }

    /// Records one position, halving the track when it reaches capacity so the
    /// whole route stays represented at a coarser spacing.
    private func appendTrackPoint(from observation: ParsedObservation) {
        guard let trackPaths,
              let point = TrackPoint.from(observation, paths: trackPaths, accuracy: gpsAccuracy)
        else { return }

        gpsTrack.append(point)
        if gpsTrack.count > Self.trackCapacity {
            gpsTrack = stride(from: 0, to: gpsTrack.count, by: 2).map { gpsTrack[$0] }
        }
    }

    /// Subscribes to the non-observation streams: encoder telemetry and GPS accuracy.
    private func subscribeSideChannels(of modules: [SensorModule]) {
        if let video = modules.compactMap({ $0 as? VideoOutput }).first {
            let stream = video.videoStats
            videoStatsTask = Task { [weak self] in
                for await stats in stream {
                    guard let self else { return }
                    self.videoStats = stats
                }
            }
        }
        if let gps = modules.compactMap({ $0 as? GPSOutput }).first {
            let stream = gps.accuracyUpdates
            gpsAccuracyTask = Task { [weak self] in
                for await accuracy in stream {
                    guard let self else { return }
                    self.gpsAccuracy = accuracy
                }
            }
        }
    }

    /// Ages readings out to .stale and keeps obs/s decaying when a sensor goes
    /// quiet. Without it a card would show the last value and a live rate
    /// forever after its sensor stopped producing.
    private func startStaleTicker() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return  // cancelled
                }
                guard let self else { return }
                self.refreshAvailability()
            }
        }
    }

    private func refreshAvailability() {
        let now = Date()
        for name in sensorOrder {
            sensors[name]?.refreshAvailability(now: now)
        }
        liveActivity.heartbeat(isConnected: isNetworkConnected)
    }

    // MARK: - User-facing error messages

    static func userFacingMessage(for error: Error) -> (title: String, suggestion: String) {
        if let clientErr = error as? ClientError {
            switch clientErr {
            case .invalidURL:
                return ("Invalid server URL",
                        "Check the URL in Settings — it should start with http:// or https://")
            case .httpError(401):
                return ("Authentication failed",
                        "Check your username and password in Settings")
            case .httpError(let code):
                return ("Server error (\(code))",
                        "The OSH node returned an unexpected response")
            case .missingLocation:
                return ("Registration failed",
                        "The server accepted the request but returned no resource ID")
            default:
                break
            }
        }

        // Shared with the connectivity test so the Systems tab status row, this
        // banner and the log all say the same thing about the same failure.
        if let urlErr = error as? URLError,
           let mapped = ConnectionErrorMessage.userFacing(for: urlErr) {
            return mapped
        }

        return ("Connection failed",
                "An unexpected error occurred — check Settings and try again")
    }
}
