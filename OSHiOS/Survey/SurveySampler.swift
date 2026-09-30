import Foundation
import CoreLocation
import CoreMotion
import Combine

// MARK: - SurveySampler
//
// The phone's position and attitude, live, for a survey-in.
//
// Separate from GPSOutput and OrientationOutputCoordinator on purpose. Those
// exist to *publish*: they are wired into SensorSession, registered as
// datastreams on the node, and stopping them stops a stream somebody may be
// watching. A survey borrows the same hardware for half a minute and must not
// touch that path. It also needs things the publishing outputs deliberately
// leave out — horizontal accuracy on every fix, CoreLocation's own heading
// accuracy, the magnetometer's calibration state — because a survey is only as
// good as the figures it can show the user before they commit to it.
//
// Two altitudes are kept for every fix. `ellipsoidalAltitude` (height above the
// WGS 84 ellipsoid) is what gets written: a SensorML position in EPSG 4979 is
// defined in that datum. `altitude` (above mean sea level) is what every GPS
// app shows, and the two differ by the geoid undulation — some thirty metres
// in the eastern United States — so both are carried and both are displayed,
// labelled, to stop that difference being mistaken for a bug.
//
// Heading comes from CMDeviceMotion in the xTrueNorthZVertical frame, so it is
// referenced to true north with CoreMotion applying the declination. Two
// cross-checks travel beside it: the heading CoreLocation's compass reports,
// with the accuracy figure only that API provides, and the magnetometer
// calibration CoreMotion attaches to each sample. A camera on a steel mount is
// exactly where a magnetometer misbehaves, and the alignment screen has to be
// able to say so.

@MainActor
final class SurveySampler: ObservableObject {

    // MARK: Types

    enum MagnetometerCalibration: Equatable, Sendable {
        case unknown, uncalibrated, low, medium, high

        var label: String {
            switch self {
            case .unknown:      return "unknown"
            case .uncalibrated: return "uncalibrated"
            case .low:          return "low"
            case .medium:       return "medium"
            case .high:         return "high"
            }
        }

        var isPoor: Bool { self == .uncalibrated || self == .low }

        init(_ accuracy: CMMagneticFieldCalibrationAccuracy) {
            switch accuracy {
            case .uncalibrated: self = .uncalibrated
            case .low:          self = .low
            case .medium:       self = .medium
            case .high:         self = .high
            @unknown default:   self = .unknown
            }
        }
    }

    /// Everything the alignment screen shows, as one value.
    struct Reading: Equatable, Sendable {
        /// The most recent fix with a valid horizontal accuracy.
        var location: LocationSample?
        /// The most recent attitude, heading from CMDeviceMotion.
        var orientation: OrientationSample?
        /// `CLHeading.headingAccuracy`, degrees. nil until the compass has
        /// reported, negative when CoreLocation considers it invalid.
        var headingAccuracy: Double?
        /// `CLHeading.trueHeading`, for cross-checking the motion heading. nil
        /// when the compass has no true-north reference (no location fix yet).
        var compassTrueHeading: Double?
        /// The heading the −yaw formula gives (what EulerOrientationOutput
        /// publishes), for diagnostics beside the CMDeviceMotion one.
        var yawHeading: Double?
        var calibration: MagnetometerCalibration = .unknown

        /// True when the compass has a true-north reference. Without one
        /// CoreMotion's "true north" frame silently degrades to magnetic north.
        var hasTrueNorth: Bool { compassTrueHeading != nil }
    }

    // MARK: Published state

    @Published private(set) var reading = Reading()
    @Published private(set) var authorization: CLAuthorizationStatus
    /// A permission or hardware problem the survey cannot proceed past.
    @Published private(set) var failure: String?

    // MARK: Configuration

    /// 20 Hz: enough that a five-second capture averages a hundred attitude
    /// samples, and no more than the display could show.
    static let motionInterval: TimeInterval = 1.0 / 20
    /// Fixes older than this on arrival are CoreLocation replaying its cache,
    /// not a measurement taken now.
    static let maxFixAge: TimeInterval = 10

    // MARK: Private

    private let locationManager = CLLocationManager()
    private let locationDelegate = LocationDelegate()
    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "osh.survey.motion"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var isRunning = false

    // MARK: Init

    init() {
        authorization = locationManager.authorizationStatus
        locationManager.delegate = locationDelegate
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.headingFilter = 1
        locationManager.headingOrientation = .portrait

        locationDelegate.onLocation = { [weak self] sample in
            Task { @MainActor [weak self] in self?.apply(location: sample) }
        }
        locationDelegate.onHeading = { [weak self] accuracy, trueHeading in
            Task { @MainActor [weak self] in
                self?.apply(headingAccuracy: accuracy, trueHeading: trueHeading)
            }
        }
        locationDelegate.onAuthorization = { [weak self] status in
            Task { @MainActor [weak self] in self?.apply(authorization: status) }
        }
        locationDelegate.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                Log.sensors.error("Survey location error: \(message, privacy: .public)")
                self?.failure = self?.failure ?? message
            }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        failure = nil

        switch locationManager.authorizationStatus {
        case .denied, .restricted:
            failure = "Location permission denied — allow it in Settings to survey a position"
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        default:
            break
        }
        // Started regardless of the answer: on authorization they begin
        // delivering, and until then they are harmless.
        locationManager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            locationManager.startUpdatingHeading()
        }

        guard motionManager.isDeviceMotionAvailable else {
            failure = failure ?? "Device motion is not available on this device"
            return
        }
        motionManager.deviceMotionUpdateInterval = Self.motionInterval
        motionManager.startDeviceMotionUpdates(using: .xTrueNorthZVertical,
                                               to: motionQueue) { [weak self] motion, error in
            if let error {
                let message = error.localizedDescription
                Task { @MainActor [weak self] in
                    Log.sensors.error("Survey motion error: \(message, privacy: .public)")
                    self?.failure = self?.failure ?? "Motion sensors failed: \(message)"
                }
                return
            }
            guard let motion else { return }
            // Reduced to plain numbers here, on the motion queue, so nothing
            // non-Sendable crosses to the main actor.
            let sample = Self.orientationSample(from: motion)
            let yawHeading = EulerOrientationOutput.normalizedHeading(fromYaw: motion.attitude.yaw)
            let calibration = MagnetometerCalibration(motion.magneticField.accuracy)
            Task { @MainActor [weak self] in
                self?.apply(orientation: sample, yawHeading: yawHeading, calibration: calibration)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        motionManager.stopDeviceMotionUpdates()
    }

    // MARK: Reduction

    /// One attitude sample from a device-motion update.
    ///
    /// `CMDeviceMotion.heading` is the direction the device points, in degrees
    /// clockwise from the frame's X axis — true north here — and is defined
    /// whether the phone is held flat or upright, which the raw yaw is not.
    /// It is negative only when the frame has no north reference, in which
    /// case the −yaw formula stands in. Pitch and roll are reported as
    /// CoreMotion gives them (radians → degrees, right-handed about the
    /// device's X and Y axes) and labelled as the *phone's* on the review
    /// screen, since a phone sighting along a lens is not level.
    nonisolated static func orientationSample(from motion: CMDeviceMotion) -> OrientationSample {
        let heading = motion.heading >= 0
            ? motion.heading
            : EulerOrientationOutput.normalizedHeading(fromYaw: motion.attitude.yaw)
        return OrientationSample(heading: SurveyMath.normalizedDegrees(heading),
                                 pitch: motion.attitude.pitch * 180 / .pi,
                                 roll: motion.attitude.roll * 180 / .pi,
                                 timestamp: Date())
    }

    // MARK: Applying

    private func apply(location: LocationSample) {
        reading.location = location
    }

    private func apply(headingAccuracy: Double, trueHeading: Double) {
        reading.headingAccuracy = headingAccuracy
        reading.compassTrueHeading = trueHeading >= 0 ? trueHeading : nil
    }

    private func apply(orientation: OrientationSample,
                       yawHeading: Double,
                       calibration: MagnetometerCalibration) {
        reading.orientation = orientation
        reading.yawHeading = yawHeading
        reading.calibration = calibration
    }

    private func apply(authorization status: CLAuthorizationStatus) {
        authorization = status
        switch status {
        case .denied, .restricted:
            failure = "Location permission denied — allow it in Settings to survey a position"
        case .authorizedWhenInUse, .authorizedAlways:
            if failure?.hasPrefix("Location permission") == true { failure = nil }
        default:
            break
        }
    }
}

// MARK: - LocationDelegate

/// CoreLocation's callbacks, reduced to Sendable values.
///
/// A separate object rather than the sampler itself because
/// CLLocationManagerDelegate's methods are not actor-isolated, and a
/// @MainActor class cannot implement them without either unsafe assumptions or
/// a nonisolated wrapper — which is all this is. Callbacks arrive on the main
/// thread (the manager was created there) and hop explicitly anyway, so the
/// reasoning does not depend on it.
///
/// @unchecked Sendable: the closures are set once, before the manager starts,
/// and only read afterwards.
private final class LocationDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {

    var onLocation: (@Sendable (LocationSample) -> Void)?
    var onHeading: (@Sendable (_ accuracy: Double, _ trueHeading: Double) -> Void)?
    var onAuthorization: (@Sendable (CLAuthorizationStatus) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            // A negative accuracy is CoreLocation's "none"; a stale timestamp
            // is a replayed cache entry. Neither is a survey sample.
            guard location.horizontalAccuracy >= 0,
                  Date().timeIntervalSince(location.timestamp) < SurveySampler.maxFixAge
            else { continue }
            onLocation?(LocationSample(latitude: location.coordinate.latitude,
                                       longitude: location.coordinate.longitude,
                                       ellipsoidalAltitude: location.ellipsoidalAltitude,
                                       altitudeMSL: location.altitude,
                                       horizontalAccuracy: location.horizontalAccuracy,
                                       verticalAccuracy: location.verticalAccuracy,
                                       timestamp: location.timestamp))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        onHeading?(newHeading.headingAccuracy, newHeading.trueHeading)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorization?(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient and CoreLocation keeps trying;
        // reporting it would flash an error over a survey that is about to
        // succeed.
        if let clError = error as? CLError, clError.code == .locationUnknown { return }
        onError?(error.localizedDescription)
    }

    /// Never suppress the calibration prompt: a survey is the one time the
    /// user wants to know the compass is unsure.
    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }
}
