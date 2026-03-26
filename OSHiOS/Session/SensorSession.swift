import Foundation
import Combine

// MARK: - SensorSession
//
// Owns the full lifecycle for one "run":
//   1. Build sensor modules from config
//   2. Register system with OSH node (POST /api/systems)
//   3. Register one datastream per module (POST /api/systems/{id}/datastreams)
//   4. Subscribe each module's Combine publisher → ObservationPublisher → POST observations

@MainActor
final class SensorSession: ObservableObject {

    enum State: Equatable {
        case idle
        case registering(String)   // message describing current step
        case streaming
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var sensorStatus: [String: String] = [:]

    private var modules: [SensorModule] = []
    private var orientCoord: OrientationOutputCoordinator?
    private var client: ConnectedSystemsClient?
    private var publisher: ObservationPublisher?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Start

    func start(config: AppConfig) {
        guard state == .idle else { return }
        Task { await run(config: config) }
    }

    func stop() {
        cancellables.removeAll()
        publisher?.stopAll()
        for m in modules { m.stop() }
        orientCoord?.stop()
        modules = []
        orientCoord = nil
        client = nil
        publisher = nil
        sensorStatus = [:]
        state = .idle
    }

    // MARK: - Internal

    private func run(config: AppConfig) async {
        // ── Step 1: Build sensor modules ──────────────────────────────────────
        setState(.registering("Building sensor modules…"))
        let descriptor = SystemDescriptor(config: config)

        var builtModules: [SensorModule] = []

        if config.enableGPS {
            let gps = GPSOutput(localFrameURI: descriptor.localFrameURI)
            builtModules.append(gps)
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

        // ── Step 2: Connect to OSH node ───────────────────────────────────────
        setState(.registering("Connecting to \(config.nodeURL)…"))
        let client: ConnectedSystemsClient
        do {
            client = try ConnectedSystemsClient(
                nodeURL: config.nodeURL,
                username: config.username,
                password: config.password
            )
        } catch {
            setState(.error("Invalid server URL: \(error.localizedDescription)"))
            return
        }
        self.client = client

        // ── Step 3: Register system ───────────────────────────────────────────
        setState(.registering("Registering system…"))
        let systemId: String
        do {
            systemId = try await SystemRegistration.registerIfNeeded(
                client: client,
                descriptor: descriptor
            )
        } catch {
            setState(.error("System registration failed: \(error.localizedDescription)"))
            return
        }

        // ── Step 4: Configure hardware (resolves actual sensor dimensions) ──────
        // VideoOutput.configure() runs configureSession() and reads the real
        // camera output dimensions after portrait rotation — must happen before
        // datastream registration so the schema has the correct width/height.
        setState(.registering("Configuring sensors…"))
        var configuredModules = builtModules
        for module in builtModules {
            do {
                try module.configure()
            } catch SensorError.unavailable(let msg) {
                sensorStatus[module.outputName] = "Unavailable: \(msg)"
                configuredModules.removeAll { $0.outputName == module.outputName }
            } catch {
                setState(.error("Sensor configuration failed: \(error.localizedDescription)"))
                return
            }
        }
        builtModules = configuredModules

        // ── Step 5: Register datastreams ──────────────────────────────────────
        setState(.registering("Registering datastreams…"))
        var datastreamIds: [String: String] = [:]
        for module in builtModules {
            do {
                let dsId = try await DatastreamRegistration.registerIfNeeded(
                    client: client,
                    systemId: systemId,
                    module: module
                )
                datastreamIds[module.outputName] = dsId
            } catch {
                setState(.error("Datastream registration failed for \(module.outputName): \(error.localizedDescription)"))
                return
            }
        }

        // ── Step 6: Wire ObservationPublisher ─────────────────────────────────
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

        // Mirror publisher's queue count into our own status
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

        // ── Step 7: Start sensors ─────────────────────────────────────────────
        setState(.registering("Starting sensors…"))

        // Try to start orientation. If hardware is unavailable (e.g. simulator),
        // remove orientation modules and continue — don't abort the whole session.
        if needsOrientation {
            do {
                try coord.start()
            } catch SensorError.unavailable(let msg) {
                sensorStatus["orientation"] = "Unavailable: \(msg)"
                builtModules.removeAll { $0 is QuatOrientationOutput || $0 is EulerOrientationOutput }
                self.orientCoord = nil
            } catch {
                setState(.error("Sensor start failed: \(error.localizedDescription)"))
                return
            }
        }

        for module in builtModules {
            guard !(module is QuatOrientationOutput),
                  !(module is EulerOrientationOutput) else { continue }
            do {
                try module.start()
            } catch SensorError.unavailable(let msg) {
                sensorStatus[module.outputName] = "Unavailable: \(msg)"
                builtModules.removeAll { $0.outputName == module.outputName }
            } catch {
                setState(.error("Sensor start failed: \(error.localizedDescription)"))
                return
            }
        }

        // Subscribe status updates from each module
        for module in builtModules {
            subscribeStatus(for: module)
        }

        setState(.streaming)
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

    // MARK: - Helpers

    private func setState(_ s: State) {
        state = s
    }
}
