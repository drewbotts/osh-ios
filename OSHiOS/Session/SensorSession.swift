import Foundation
import AVFoundation
import Combine

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
    @Published private(set) var sensorStatus: [String: String] = [:]
    /// False while streaming if the network path is unavailable (observations are buffering).
    @Published private(set) var isNetworkConnected = true

    // MARK: - Private

    private var modules: [SensorModule] = []
    private var orientCoord: OrientationOutputCoordinator?
    private var client: ConnectedSystemsClient?
    private var publisher: ObservationPublisher?
    private var cancellables = Set<AnyCancellable>()
    private var runTask: Task<Void, Never>?
    /// Tracks the best-effort Garmin registration task so stop() can cancel it.
    private var garminTask: Task<Void, Never>?

    // MARK: - Public API

    /// Begin a new session. Allowed from .idle or .failed (retry path).
    func start(config: AppConfig,
               server: ServerConfig,
               systemName: String,
               garminSettings: GarminSettingsStore? = nil) {
        switch state {
        case .idle, .failed: break
        default: return  // already connecting or streaming
        }
        sensorStatus = [:]
        runTask = Task {
            await run(config: config,
                      server: server,
                      systemName: systemName,
                      garminSettings: garminSettings)
        }
    }

    /// Stop an active streaming session and return to .idle.
    func stop() {
        garminTask?.cancel()
        garminTask = nil
        runTask?.cancel()
        runTask = nil
        cleanupModules()
        sensorStatus = [:]
        isNetworkConnected = true
        state = .idle
    }

    /// Cancel a startup that is currently .connecting and return to .idle.
    func cancelStartup() {
        guard case .connecting = state else { return }
        stop()
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

    // MARK: - Run loop

    private func run(config: AppConfig,
                     server: ServerConfig,
                     systemName: String,
                     garminSettings: GarminSettingsStore? = nil) async {
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

            let coord = OrientationOutputCoordinator(localFrameURI: descriptor.localFrameURI)
            if config.enableOrientationQuat  { builtModules.append(coord.quatOutput) }
            if config.enableOrientationEuler { builtModules.append(coord.eulerOutput) }
            let needsOrientation = config.enableOrientationQuat || config.enableOrientationEuler
            if needsOrientation { self.orientCoord = coord }

            if config.enableBarometer  { builtModules.append(BarometerOutput()) }
            if config.enableAudioLevel { builtModules.append(AudioLevelOutput()) }
            if config.enableVideoH264  { builtModules.append(VideoOutputH264(config: config.videoConfig)) }

            self.modules = builtModules

            // ── Step 2: Create client ─────────────────────────────────────────
            try advance(to: "Connecting to \(server.url)…")
            let client = try ConnectedSystemsClient(
                nodeURL: server.url,
                username: server.username,
                password: server.password
            )
            self.client = client

            // ── Step 3: Register system ───────────────────────────────────────
            try advance(to: "Registering system…")
            let systemId = try await SystemRegistration.registerIfNeeded(
                client: client,
                descriptor: descriptor
            )

            // ── Step 4: Configure hardware ────────────────────────────────────
            try advance(to: "Configuring sensors…")
            var configuredModules = builtModules
            for module in builtModules {
                do {
                    try module.configure()
                } catch SensorError.unavailable(let msg) {
                    sensorStatus[module.outputName] = "Unavailable: \(msg)"
                    configuredModules.removeAll { $0.outputName == module.outputName }
                }
                // Non-unavailable errors propagate to the outer catch → .failed
            }
            builtModules = configuredModules

            // ── Step 5: Register datastreams ──────────────────────────────────
            try advance(to: "Registering datastreams…")
            var datastreamIds: [String: String] = [:]
            for module in builtModules {
                let dsId = try await DatastreamRegistration.registerIfNeeded(
                    client: client,
                    systemId: systemId,
                    module: module
                )
                datastreamIds[module.outputName] = dsId
            }

            // ── Step 6: Wire ObservationPublisher ─────────────────────────────
            var datastreamSchemas: [String: DataRecord] = [:]
            for module in builtModules {
                datastreamSchemas[module.outputName] = module.recordDescription
            }

            let pub = ObservationPublisher()
            pub.configure(client: client, systemId: systemId,
                          datastreamIds: datastreamIds,
                          datastreamSchemas: datastreamSchemas)
            pub.subscribe(to: builtModules)
            pub.startNetworkMonitoring()
            self.publisher = pub

            pub.$queuedCount
                .receive(on: DispatchQueue.main)
                .sink { [weak self] count in
                    if count > 0 {
                        self?.sensorStatus["queue"] = "\(count) buffered"
                    } else {
                        self?.sensorStatus.removeValue(forKey: "queue")
                    }
                }
                .store(in: &cancellables)

            pub.$isConnected
                .receive(on: DispatchQueue.main)
                .sink { [weak self] connected in self?.isNetworkConnected = connected }
                .store(in: &cancellables)

            // ── Step 7: Start sensors ─────────────────────────────────────────
            // Activate a background-compatible audio session so iOS keeps the app
            // (and AVCaptureSession) running when the screen locks.
            // .playAndRecord with .mixWithOthers = capture without interrupting other audio.
            // This must be set before AVCaptureSession starts running.
            let audioSession = AVAudioSession.sharedInstance()
            try? audioSession.setCategory(.playAndRecord,
                                          mode: .videoRecording,
                                          options: [.mixWithOthers])
            try? audioSession.setActive(true)

            try advance(to: "Starting sensors…")

            if needsOrientation {
                do {
                    try coord.start()
                } catch SensorError.unavailable(let msg) {
                    sensorStatus["orientation"] = "Unavailable: \(msg)"
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
                    sensorStatus[module.outputName] = "Unavailable: \(msg)"
                    builtModules.removeAll { $0.outputName == module.outputName }
                }
                // Non-unavailable errors propagate to outer catch → .failed
            }

            for module in builtModules {
                subscribeStatus(for: module)
            }

            // ── Done ──────────────────────────────────────────────────────────
            succeeded = true
            state = .streaming

            // ── Optional: Garmin real-time streaming ──────────────────────────
            // Best-effort — failures are logged but do not abort the main session.
            // Stored in garminTask so stop() can cancel it if the session ends
            // before Garmin registration completes.
            if let garminSettings,
               garminSettings.settings.streamingMode == .realTime,
               case .connected(let deviceName) = GarminManager.shared.deviceState,
               let unitID = GarminManager.shared.connectedUnitID {
                garminTask = Task { @MainActor [weak self] in
                    await self?.startGarminStreaming(
                        client: client,
                        systemId: systemId,
                        publisher: pub,
                        garminSettings: garminSettings,
                        deviceName: deviceName,
                        unitID: unitID,
                        localFrameURI: descriptor.localFrameURI
                    )
                }
            }

        } catch {
            // Single exit point for all failures.
            // If the task was cancelled, stop() already set state = .idle — leave it.
            if !Task.isCancelled {
                state = .failed(error)
            }
            // defer handles cleanupModules()
        }
    }

    /// Checks for task cancellation, then advances the connecting status message.
    /// Throws CancellationError if the task was cancelled, unwinding the run() do/catch.
    private func advance(to message: String) throws {
        try Task.checkCancellation()
        state = .connecting(message)
    }

    // MARK: - Garmin streaming

    private var garminOutputs: [SensorModule] = []

    /// Registers the Garmin wearable as a child system, registers its datastreams,
    /// subscribes outputs to the shared ObservationPublisher, and starts real-time streaming.
    /// All errors are caught and logged — Garmin failure never stops the main session.
    private func startGarminStreaming(
        client: ConnectedSystemsClient,
        systemId: String,
        publisher: ObservationPublisher,
        garminSettings: GarminSettingsStore,
        deviceName: String,
        unitID: UInt32,
        localFrameURI: String
    ) async {
        // Bail out immediately if the session was stopped before we even started.
        guard !Task.isCancelled else { return }

        do {
            let descriptor = GarminSystemDescriptor(unitID: unitID, deviceName: deviceName)

            // Register the Garmin device as a subsystem of the phone system
            let garminSystemId = try await client.registerSubsystem(
                parentSystemId: systemId,
                descriptor: descriptor
            )

            // If stop() was called while we awaited registration, abort cleanly.
            try Task.checkCancellation()

            // Build outputs according to enabled data types
            var outputs: [SensorModule] = []
            let mgr = GarminManager.shared
            if garminSettings.settings.enableHeartRate {
                outputs.append(GarminHeartRateOutput(source: mgr.heartRatePublisher))
            }
            if garminSettings.settings.enableStress {
                outputs.append(GarminStressOutput(source: mgr.stressPublisher))
            }
            if garminSettings.settings.enableRespiration {
                outputs.append(GarminRespirationOutput(source: mgr.respirationPublisher))
            }
            if garminSettings.settings.enableAccelerometer {
                outputs.append(GarminAccelerometerOutput(
                    source: mgr.accelerometerPublisher,
                    localFrameURI: descriptor.localFrameURI
                ))
            }

            // Register datastreams for each output.
            // All registrations must succeed before we wire anything — this prevents
            // partial state where only some datastreams are routed in the publisher.
            var garminIds: [String: String] = [:]
            var garminSchemas: [String: DataRecord] = [:]
            for output in outputs {
                try Task.checkCancellation()
                let dsId = try await DatastreamRegistration.registerIfNeeded(
                    client: client,
                    systemId: garminSystemId,
                    module: output
                )
                garminIds[output.outputName]     = dsId
                garminSchemas[output.outputName] = output.recordDescription
            }

            try Task.checkCancellation()

            // All registrations succeeded — wire into the shared publisher.
            publisher.addDatastreams(ids: garminIds, schemas: garminSchemas)
            publisher.subscribeGarmin(to: outputs)

            // Start each output (subscribes to GarminManager publishers).
            // Track started outputs so the catch block can stop them on failure.
            var startedOutputs: [SensorModule] = []
            for output in outputs {
                try output.start()
                startedOutputs.append(output)
            }
            self.garminOutputs = startedOutputs

            // Kick off real-time streaming on the device
            GarminManager.shared.startRealTimeStreaming()

            sensorStatus["garmin"] = deviceName

        } catch is CancellationError {
            // Session was stopped — stop the device stream and clean up started outputs.
            GarminManager.shared.stopRealTimeStreaming()
            for m in garminOutputs { m.stop() }
            garminOutputs = []
            sensorStatus.removeValue(forKey: "garmin")
            // Server-side registrations (subsystem + datastreams) are left in place;
            // they will be reused on the next session start via registerIfNeeded caching.

        } catch {
            // Stop any outputs started before the failure.
            for m in garminOutputs { m.stop() }
            garminOutputs = []
            // Note: if registerSubsystem succeeded before this throw, the subsystem
            // and any partially-registered datastreams remain on the server.
            // They will be reused on retry once GarminSystemRegistration caching is added (H2).
            print("[SensorSession] Garmin integration failed: \(error.localizedDescription)")
            sensorStatus["garmin"] = "Unavailable: \(error.localizedDescription)"
        }
    }

    // MARK: - Cleanup

    private func cleanupModules() {
        garminTask?.cancel()
        garminTask = nil
        GarminManager.shared.stopRealTimeStreaming()
        cancellables.removeAll()
        publisher?.stopAll()
        try? AVAudioSession.sharedInstance().setActive(false,
            options: .notifyOthersOnDeactivation)
        for m in modules { m.stop() }
        for m in garminOutputs { m.stop() }
        orientCoord?.stop()
        modules       = []
        garminOutputs = []
        orientCoord   = nil
        client        = nil
        publisher     = nil
    }

    // MARK: - Live status subscriptions

    private func subscribeStatus(for module: SensorModule) {
        module.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] obs in
                guard let self else { return }
                switch obs.payload {
                case .scalar(let v) where v.count >= 4 && module is GPSOutput:
                    if v[1].isFinite && v[2].isFinite {
                        self.sensorStatus[module.outputName] = String(format: "%.5f, %.5f", v[1], v[2])
                    }
                case .scalar(let v) where v.count >= 2 && module is EulerOrientationOutput:
                    if v[1].isFinite {
                        self.sensorStatus[module.outputName] = String(format: "hdg %.1f°", v[1])
                    }
                case .scalar(let v) where module is QuatOrientationOutput:
                    if v.dropFirst().allSatisfy(\.isFinite) {
                        self.sensorStatus[module.outputName] = "active"
                    }
                case .scalar(let v) where v.count >= 2 && module is BarometerOutput:
                    if v[1].isFinite {
                        self.sensorStatus[module.outputName] = String(format: "%.1f hPa", v[1])
                    }
                case .scalar(let v) where v.count >= 2 && module is AudioLevelOutput:
                    if v[1].isFinite {
                        self.sensorStatus[module.outputName] = String(format: "%.1f dB", v[1])
                    }
                case .video:
                    self.sensorStatus[module.outputName] = "streaming"
                default:
                    break
                }
            }
            .store(in: &cancellables)
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

        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return ("No internet connection",
                        "Check your network connection and try again")
            case .timedOut:
                return ("Connection timed out",
                        "The server took too long to respond — check the URL and try again")
            case .cannotConnectToHost, .cannotFindHost:
                return ("Cannot reach server",
                        "Check the server URL and make sure the OSH node is running")
            default:
                break
            }
        }

        return ("Connection failed",
                "An unexpected error occurred — check Settings and try again")
    }
}
