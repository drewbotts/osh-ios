import Foundation
import Combine

// MARK: - Compile flag
//
// Set garminLicenseAvailable = true and add the Garmin Connect IQ SDK
// framework once a license key is obtained.  Until then the manager
// stubs every state transition so the rest of the app can compile and
// run without the SDK present.

private let garminLicenseAvailable = false

// MARK: - GarminDeviceState

enum GarminDeviceState: Equatable {
    case sdkUnavailable          // SDK not linked / no license
    case notInitialized          // SDK present but not started
    case initializing            // SDK starting up
    case ready                   // SDK initialised, no device paired
    case scanning                // BLE scan in progress
    case connecting(String)      // connecting to a named device
    case connected(String)       // connected device name
    case syncing(String)         // FIT sync running for named device
    case error(String)           // SDK or device error
}

// MARK: - GarminSyncResult

struct GarminSyncResult {
    let deviceName: String
    let fitFileCount: Int
    let timestamp: Date
}

// MARK: - GarminManager
//
// @MainActor singleton that owns the Garmin Connect IQ SDK lifecycle.
//
// When garminLicenseAvailable == false every public method is a no-op and
// deviceState is .sdkUnavailable, letting all UI and session code compile
// without the SDK.
//
// When the SDK is present (garminLicenseAvailable == true):
//   - Conforms to all relevant Garmin delegate protocols
//   - Publishes real-time streams (HR, stress, accelerometer)
//   - Publishes FIT sync results
//   - Exposes start/stop for real-time streaming and manual sync

@MainActor
final class GarminManager: ObservableObject {

    // MARK: - Singleton

    static let shared = GarminManager()
    private init() {
        if garminLicenseAvailable {
            // SDK init would go here
        } else {
            deviceState = .sdkUnavailable
        }
    }

    // MARK: - Published state

    @Published private(set) var deviceState: GarminDeviceState = .sdkUnavailable
    @Published private(set) var pairedDeviceName: String?

    /// The hardware unit ID of the connected Garmin device, or nil if not connected.
    /// Populated by the real SDK delegate; nil in the stub / when no device paired.
    @Published private(set) var connectedUnitID: UInt32?

    // MARK: - Combine publishers
    //
    // Each publishes a flat [Double] matching the corresponding SWE schema.
    //
    // Thread-safety contract: these subjects MUST only be sent to on the main thread.
    // The stub simulate* methods are @MainActor-bound and are safe.
    // When implementing real SDK delegates (RealTimeDelegate etc.), use
    // sendOnMain(_:value:) rather than calling subject.send() directly —
    // SDK callbacks arrive on background threads.

    let heartRatePublisher      = PassthroughSubject<[Double], Never>()
    let stressPublisher         = PassthroughSubject<[Double], Never>()
    let respirationPublisher    = PassthroughSubject<[Double], Never>()
    let accelerometerPublisher  = PassthroughSubject<[Double], Never>()
    let fitSyncPublisher        = PassthroughSubject<GarminSyncResult, Never>()

    // MARK: - Public API

    /// Initialise the SDK with the provided license key.
    /// No-op when garminLicenseAvailable == false.
    func start(licenseKey: String) {
        guard garminLicenseAvailable else { return }
        deviceState = .initializing
        // SDK init call would go here
        // On success:  deviceState = .ready
        // On failure:  deviceState = .error(msg)
    }

    /// Tear down the SDK and disconnect any device.
    func stop() {
        guard garminLicenseAvailable else { return }
        stopRealTimeStreaming()
        deviceState = .notInitialized
    }

    /// Begin a BLE scan for nearby Garmin devices.
    func startScan() {
        guard garminLicenseAvailable else { return }
        guard case .ready = deviceState else { return }
        deviceState = .scanning
        // DeviceManager.startScan() would go here
    }

    /// Cancel an in-progress BLE scan.
    func stopScan() {
        guard garminLicenseAvailable else { return }
        guard case .scanning = deviceState else { return }
        deviceState = .ready
        // DeviceManager.stopScan() would go here
    }

    /// Connect to a discovered Garmin device by name.
    func connect(deviceName: String) {
        guard garminLicenseAvailable else { return }
        deviceState = .connecting(deviceName)
        // DeviceManager.connect(device) would go here
    }

    /// Disconnect from the current device.
    func disconnect() {
        guard garminLicenseAvailable else { return }
        pairedDeviceName = nil
        deviceState = .ready
        // DeviceManager.disconnect() would go here
    }

    /// Start Garmin real-time streaming (HR, stress, respiration, accelerometer).
    func startRealTimeStreaming() {
        guard garminLicenseAvailable else { return }
        guard case .connected = deviceState else { return }
        // ConfigurationManager / RealTimeDelegate setup would go here
    }

    /// Stop Garmin real-time streaming.
    func stopRealTimeStreaming() {
        guard garminLicenseAvailable else { return }
        // ConfigurationManager.stopRealTimeStreaming() would go here
    }

    /// Trigger an immediate FIT file sync from the device.
    func syncNow() {
        guard garminLicenseAvailable else { return }
        guard case .connected(let name) = deviceState else { return }
        deviceState = .syncing(name)
        // SyncDelegate.startSync() would go here
    }

    // MARK: - Thread-safe send

    /// Dispatches a subject send to the main thread.
    /// Use this in all real SDK delegate implementations instead of subject.send() directly.
    private func sendOnMain<T>(_ subject: PassthroughSubject<T, Never>, value: T) {
        if Thread.isMainThread {
            subject.send(value)
        } else {
            DispatchQueue.main.async { subject.send(value) }
        }
    }

    // MARK: - Mock helpers (DEBUG only)
    //
    // Allows UI and session integration tests to exercise state transitions
    // without real hardware or the SDK.

    #if DEBUG
    func simulateConnected(deviceName: String, unitID: UInt32 = 12345678) {
        connectedUnitID = unitID
        pairedDeviceName = deviceName
        deviceState = .connected(deviceName)
    }

    func simulateHeartRate(bpm: Double) {
        let t = Date().timeIntervalSince1970
        heartRatePublisher.send([t, bpm])
    }

    func simulateStress(score: Double) {
        let t = Date().timeIntervalSince1970
        stressPublisher.send([t, score])
    }

    func simulateRespiration(breathsPerMinute: Double) {
        let t = Date().timeIntervalSince1970
        respirationPublisher.send([t, breathsPerMinute])
    }

    func simulateAccelerometer(ax: Double, ay: Double, az: Double) {
        let t = Date().timeIntervalSince1970
        accelerometerPublisher.send([t, ax, ay, az])
    }

    func simulateFITSync(deviceName: String, fileCount: Int) {
        fitSyncPublisher.send(GarminSyncResult(deviceName: deviceName,
                                               fitFileCount: fileCount,
                                               timestamp: Date()))
    }
    #endif
}

// MARK: - SDK delegate stubs
//
// When garminLicenseAvailable == true, replace these empty extensions with
// the real Garmin SDK delegate conformances:
//
//   extension GarminManager: SDKStatusDelegate { ... }
//   extension GarminManager: ScanDelegate { ... }
//   extension GarminManager: ConnectionDelegate { ... }
//   extension GarminManager: SyncDelegate {
//       func syncManager(_ manager: SyncManager, didFinishWith result: SyncResult) {
//           // Parse FIT files from result.fileURLs
//           // Post to fitSyncPublisher
//       }
//   }
//   extension GarminManager: RealTimeDelegate {
//       func manager(_ manager: RealTimeManager, didReceiveHeartRate bpm: Int, ...) {
//           let t = Date().timeIntervalSince1970
//           heartRatePublisher.send([t, Double(bpm)])
//       }
//       // ... stress, respiration, accelerometer
//   }
