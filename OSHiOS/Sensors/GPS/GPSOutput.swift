import Foundation
import CoreLocation
import Combine

// MARK: - GPSOutput
//
// iOS equivalent of AndroidLocationOutput.
//
// SWE schema (mirroring AndroidLocationOutput exactly):
//   DataRecord definition = "http://sensorml.com/ont/swe/property/Location"
//   Fields:
//     0: time     — Double, Unix wall-clock seconds (location.timestamp.timeIntervalSince1970)
//     1: lat      — Double, degrees
//     2: lon      — Double, degrees
//     3: alt      — Double, metres (altitude above ellipsoid; CLLocation.altitude is HAE on iOS)
//
// Update interval: 1 Hz  (matches Android: minTime = 1000 ms, minDistance = 0 m)
//
// Note on timestamps: AndroidLocationOutput uses location.getTime()/1000.0 which is
// milliseconds-since-epoch / 1000 = seconds since Unix epoch (NOT J2000).
// CLLocation.timestamp.timeIntervalSince1970 gives the same quantity on iOS.

// @unchecked Sendable: CLLocationManager is not Sendable, but it is a `let` that
// is only ever driven from the main actor (start/stop) and its delegate callbacks
// arrive on the main queue, so there is no concurrent access to synchronise.
final class GPSOutput: NSObject, SensorModule, @unchecked Sendable {
    let outputName: String
    let recordDescription: DataRecord
    let recommendedEncoding: BinaryEncoding
    let averageSamplingPeriod: Double = 1.0

    private let subject = PassthroughSubject<Observation, Never>()
    var publisher: AnyPublisher<Observation, Never> { subject.eraseToAnyPublisher() }

    private let locationManager: CLLocationManager
    private let localFrameURI: String

    // MARK: Accuracy side channel
    //
    // Horizontal accuracy is not part of the SWE record — the Android driver's
    // Location schema is time + lat/lon/alt and this app must register the same
    // one — but the map needs it to draw an accuracy circle. It travels beside
    // the observations rather than inside them.

    private let accuracyRelay = AsyncValueRelay<Double>()

    /// Metres of horizontal accuracy for the most recent fix. Negative values
    /// (CoreLocation's "invalid") are never published.
    var accuracyUpdates: AsyncStream<Double> { accuracyRelay.stream() }

    // MARK: Init

    init(localFrameURI: String) {
        self.localFrameURI = localFrameURI

        // Build SWE schema matching AndroidLocationOutput
        let name = "gps_data"
        self.outputName = name
        self.recordDescription = GeoPosHelper.newLocationRecord(
            name: name,
            localFrameURI: localFrameURI
        )
        self.recommendedEncoding = BinaryEncoding(fields: [
            BinaryFieldEncoding(ref: "/time", type: .scalar(.double)),
            BinaryFieldEncoding(ref: "/location/lat", type: .scalar(.double)),
            BinaryFieldEncoding(ref: "/location/lon", type: .scalar(.double)),
            BinaryFieldEncoding(ref: "/location/alt", type: .scalar(.double))
        ])

        self.locationManager = CLLocationManager()
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter  = kCLDistanceFilterNone  // all movements
    }

    // MARK: SensorModule

    func start() throws {
        // Fail fast on a hard denial: requesting again is a no-op once the user
        // has said no, so without this check the session would report "streaming"
        // while silently producing zero fixes.
        let status = CLLocationManager().authorizationStatus
        switch status {
        case .denied, .restricted:
            throw SensorError.unavailable("Location permission denied")

        case .notDetermined:
            // Ask now; updates begin for real in locationManagerDidChangeAuthorization
            // once the user answers the prompt.
            locationManager.requestWhenInUseAuthorization()
            locationManager.startUpdatingLocation()

        default:
            enableBackgroundUpdatesIfAuthorized()
            locationManager.startUpdatingLocation()
        }
    }

    func stop() {
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        accuracyRelay.finish()
    }

    /// Keeps fixes coming while the screen is locked.
    ///
    /// Requires the "location" UIBackgroundMode, which the app declares — the
    /// property traps at runtime without it. When-in-use authorization is
    /// enough; we deliberately never ask for Always, so background delivery
    /// lasts only as long as the system's grace period for an app the user
    /// started streaming from the foreground, and the blue status indicator
    /// makes that visible.
    ///
    /// Camera, motion and audio capture are *not* covered by this: iOS
    /// suspends AVCaptureSession, CMMotionManager updates and AVAudioEngine
    /// taps when the app leaves the foreground, by platform policy. Only GPS
    /// keeps producing observations in the background.
    private func enableBackgroundUpdatesIfAuthorized() {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
        default:
            break
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension GPSOutput: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        // Timestamp: seconds since Unix epoch (matches Android location.getTime()/1000.0)
        let sampleTime = location.timestamp.timeIntervalSince1970

        // Build flat scalar array matching DataBlock layout:
        //   [time, lat, lon, alt]
        let scalars: [Double] = [
            sampleTime,
            location.coordinate.latitude,
            location.coordinate.longitude,
            location.altitude  // CLLocation.altitude = HAE on iOS (matches WGS84 ellipsoid)
        ]

        let obs = Observation(
            datastreamName: outputName,
            payload: .scalar(scalars)
        )
        subject.send(obs)

        // CoreLocation reports a negative accuracy when it has none to give.
        if location.horizontalAccuracy >= 0 {
            accuracyRelay.send(location.horizontalAccuracy)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Non-fatal; just log.  Connectivity / permission issues surface here.
        Log.sensors.error("CLLocationManager error: \(error.localizedDescription, privacy: .public)")
    }

    /// Called when the user answers the permission prompt raised by start(), and
    /// on any later change in Settings. Starting updates here is what actually
    /// gets the first fix flowing after a .notDetermined start.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            Log.sensors.info("Location authorized — starting updates")
            enableBackgroundUpdatesIfAuthorized()
            manager.startUpdatingLocation()
        case .denied, .restricted:
            Log.sensors.error("Location permission denied — GPS output will produce no data")
            manager.stopUpdatingLocation()
        default:
            break
        }
    }
}
