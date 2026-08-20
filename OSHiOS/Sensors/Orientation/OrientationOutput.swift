import Foundation
import CoreMotion
import Combine

// MARK: - OrientationOutput
//
// Produces two SensorModule outputs from one shared CMMotionManager, owned by
// OrientationOutputCoordinator. The coordinator is the single source of truth for
// the motion-update lifecycle: it creates the CMMotionManager, starts and stops
// device-motion updates, and fans each CMDeviceMotion sample out to both outputs
// via handleMotion(_:). The output classes hold no motion hardware at all — their
// start()/stop() are deliberate no-ops.
//
// ── Reference frame ──────────────────────────────────────────────────────────
// Updates are requested with CMAttitudeReferenceFrame.xTrueNorthZVertical:
//   • Z points up along the gravity vector (vertical).
//   • X points to geographic (true) north, not magnetic north — CoreMotion applies
//     the local magnetic declination using the device's location.
//   • Y completes the right-handed frame (west).
// This frame requires both the magnetometer and an active, authorized
// CLLocationManager. Without a location fix CoreMotion silently degrades to
// magnetic north, so GPSOutput should be running for headings to be true-north
// referenced.
//
// ── Heading convention ───────────────────────────────────────────────────────
// CMAttitude.yaw is the rotation about the vertical axis in radians, measured
// counter-clockwise and reported in (-π, π]. A compass heading runs clockwise
// from north over [0, 360), so we negate, convert to degrees, and wrap:
//     heading = (-yaw · 180/π) mod 360, shifted into [0, 360)
// giving 0° = true north, 90° = east, 180° = south, 270° = west.
//
// ── Quaternion output ─────────────────────────────────────────────────────────
//   name       = "quat_orientation_data"
//   definition = "http://sensorml.com/ont/swe/property/OrientationQuaternion"
//   Fields: time, qx, qy, qz, q0
//
// ── Euler output ─────────────────────────────────────────────────────────────
//   name       = "euler_orientation_data"
//   definition = "http://sensorml.com/ont/swe/property/OrientationEuler"
//   Fields: time, heading (0..360 deg), pitch (-90..90 deg), roll (-180..180 deg)
//
// Update rate: 10 Hz, matching the Android driver.

// MARK: - QuatOrientationOutput

// @unchecked Sendable: the only mutable state is the PassthroughSubject, which
// serialises its own delivery; handleMotion(_:) is called from the coordinator's
// single-width OperationQueue and never concurrently with itself.
final class QuatOrientationOutput: SensorModule, @unchecked Sendable {
    let outputName = "quat_orientation_data"
    let recordDescription: DataRecord
    let recommendedEncoding: BinaryEncoding
    let averageSamplingPeriod: Double = 0.1

    private let subject = PassthroughSubject<Observation, Never>()
    var publisher: AnyPublisher<Observation, Never> { subject.eraseToAnyPublisher() }

    init(localFrameURI: String) {
        self.recordDescription = GeoPosHelper.newQuatOrientationRecord(
            name: outputName,
            localFrameURI: localFrameURI
        )
        self.recommendedEncoding = BinaryEncoding(fields: [
            BinaryFieldEncoding(ref: "/time",       type: .scalar(.double)),
            BinaryFieldEncoding(ref: "/orient/qx",  type: .scalar(.float)),
            BinaryFieldEncoding(ref: "/orient/qy",  type: .scalar(.float)),
            BinaryFieldEncoding(ref: "/orient/qz",  type: .scalar(.float)),
            BinaryFieldEncoding(ref: "/orient/q0",  type: .scalar(.float))
        ])
    }

    /// No-op: OrientationOutputCoordinator owns the CMMotionManager and starts
    /// device-motion updates for both orientation outputs.
    func start() throws {}

    /// No-op: OrientationOutputCoordinator owns the CMMotionManager and stops
    /// device-motion updates for both orientation outputs.
    func stop() {}

    func handleMotion(_ motion: CMDeviceMotion) {
        let sampleTime = Date().timeIntervalSince1970
        let q = motion.attitude.quaternion

        // Layout: [time, qx, qy, qz, q0(scalar=w)]
        // Matching Android: att.x=rv[0], att.y=rv[1], att.z=rv[2], att.s=rv[3](w)
        let scalars: [Double] = [sampleTime, q.x, q.y, q.z, q.w]

        // Guard against NaN/Inf (simulator returns zero quaternions on cold start)
        guard scalars.allSatisfy(\.isFinite) else { return }

        subject.send(Observation(datastreamName: outputName, payload: .scalar(scalars)))
    }
}

// MARK: - EulerOrientationOutput

// @unchecked Sendable: see QuatOrientationOutput — same reasoning.
final class EulerOrientationOutput: SensorModule, @unchecked Sendable {
    let outputName = "euler_orientation_data"
    let recordDescription: DataRecord
    let recommendedEncoding: BinaryEncoding
    let averageSamplingPeriod: Double = 0.1

    private let subject = PassthroughSubject<Observation, Never>()
    var publisher: AnyPublisher<Observation, Never> { subject.eraseToAnyPublisher() }

    init(localFrameURI: String) {
        self.recordDescription = GeoPosHelper.newEulerOrientationRecord(
            name: outputName,
            localFrameURI: localFrameURI
        )
        self.recommendedEncoding = BinaryEncoding(fields: [
            BinaryFieldEncoding(ref: "/time",           type: .scalar(.double)),
            BinaryFieldEncoding(ref: "/orient/heading", type: .scalar(.float)),
            BinaryFieldEncoding(ref: "/orient/pitch",   type: .scalar(.float)),
            BinaryFieldEncoding(ref: "/orient/roll",    type: .scalar(.float))
        ])
    }

    /// No-op: OrientationOutputCoordinator owns the CMMotionManager and starts
    /// device-motion updates for both orientation outputs.
    func start() throws {}

    /// No-op: OrientationOutputCoordinator owns the CMMotionManager and stops
    /// device-motion updates for both orientation outputs.
    func stop() {}

    /// Converts a CMAttitude yaw (radians, counter-clockwise, (-π, π]) into a
    /// compass heading in degrees clockwise from true north, normalized to [0, 360).
    static func normalizedHeading(fromYaw yaw: Double) -> Double {
        var heading = -yaw * 180 / .pi
        heading = heading.truncatingRemainder(dividingBy: 360)
        if heading < 0 { heading += 360 }
        return heading
    }

    func handleMotion(_ motion: CMDeviceMotion) {
        let sampleTime = Date().timeIntervalSince1970
        let attitude = motion.attitude

        let heading = Self.normalizedHeading(fromYaw: attitude.yaw)
        let pitch = attitude.pitch * 180.0 / .pi
        let roll  = attitude.roll * 180.0 / .pi

        guard heading.isFinite, pitch.isFinite, roll.isFinite else { return }

        let scalars: [Double] = [sampleTime, heading, pitch, roll]
        subject.send(Observation(datastreamName: outputName, payload: .scalar(scalars)))
    }
}

// MARK: - Shared motion manager coordinator

/// Creates and owns the CMMotionManager; vends QuatOrientationOutput and EulerOrientationOutput
/// sharing the same underlying motion updates.
final class OrientationOutputCoordinator {
    private let motionManager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "osh.orientation"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    let quatOutput: QuatOrientationOutput
    let eulerOutput: EulerOrientationOutput

    private var isStarted = false

    init(localFrameURI: String) {
        quatOutput  = QuatOrientationOutput(localFrameURI: localFrameURI)
        eulerOutput = EulerOrientationOutput(localFrameURI: localFrameURI)
    }

    func start() throws {
        guard !isStarted else { return }
        guard motionManager.isDeviceMotionAvailable else {
            throw SensorError.unavailable("Device motion not available")
        }
        isStarted = true
        motionManager.deviceMotionUpdateInterval = 0.1
        // .xTrueNorthZVertical needs an authorized, running CLLocationManager to
        // resolve magnetic declination; without one CoreMotion falls back to
        // magnetic north silently.
        motionManager.startDeviceMotionUpdates(
            using: .xTrueNorthZVertical,
            to: queue
        ) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                Log.sensors.error("Device motion error: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let motion else { return }
            self.quatOutput.handleMotion(motion)
            self.eulerOutput.handleMotion(motion)
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        motionManager.stopDeviceMotionUpdates()
    }
}

// MARK: - Errors

enum SensorError: Error, LocalizedError {
    case unavailable(String)
    case configurationError(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let msg):        return "Sensor unavailable: \(msg)"
        case .configurationError(let msg): return "Sensor configuration error: \(msg)"
        }
    }
}
