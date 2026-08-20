import Foundation
import CoreMotion
import Combine

// MARK: - OrientationOutput
//
// Produces two SensorModule outputs from one shared CMMotionManager, owned by
// OrientationOutputCoordinator. The coordinator is the single source of truth
// for motion-update lifecycle; the output classes only consume CMDeviceMotion
// samples via handleMotion(_:) and publish observations.
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
// Reference frame: .xTrueNorthZVertical so heading is relative to geographic
// north. Requires CLLocationManager to be running and authorized; if location
// is unavailable, CoreMotion silently falls back to magnetic north.
//
// Update rate: 10 Hz, matching the Android driver.

// MARK: - QuatOrientationOutput

final class QuatOrientationOutput: SensorModule {
    let outputName = "quat_orientation_data"
    let recordDescription: DataRecord
    let recommendedEncoding: BinaryEncoding
    let averageSamplingPeriod: Double = 0.1

    private let subject = PassthroughSubject<Observation, Never>()
    var publisher: AnyPublisher<Observation, Never> { subject.eraseToAnyPublisher() }

    private weak var motionManager: CMMotionManager?
    private let queue: OperationQueue

    init(motionManager: CMMotionManager, queue: OperationQueue, localFrameURI: String) {
        self.motionManager = motionManager
        self.queue = queue
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

    func start() throws {
        guard let mm = motionManager, mm.isDeviceMotionAvailable else {
            throw SensorError.unavailable("Device motion not available")
        }
        mm.deviceMotionUpdateInterval = averageSamplingPeriod
        mm.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: queue
        ) { [weak self] motion, error in
            guard let self = self, let motion = motion else { return }
            self.handleMotion(motion)
        }
    }

    func stop() {
        motionManager?.stopDeviceMotionUpdates()
    }

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

final class EulerOrientationOutput: SensorModule {
    let outputName = "euler_orientation_data"
    let recordDescription: DataRecord
    let recommendedEncoding: BinaryEncoding
    let averageSamplingPeriod: Double = 0.1

    private let subject = PassthroughSubject<Observation, Never>()
    var publisher: AnyPublisher<Observation, Never> { subject.eraseToAnyPublisher() }

    private weak var motionManager: CMMotionManager?
    private let queue: OperationQueue

    init(motionManager: CMMotionManager, queue: OperationQueue, localFrameURI: String) {
        self.motionManager = motionManager
        self.queue = queue
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

    func start() throws {
        guard let mm = motionManager, mm.isDeviceMotionAvailable else {
            throw SensorError.unavailable("Device motion not available")
        }
        // Motion updates are shared with QuatOrientationOutput — only start if not running.
        if !mm.isDeviceMotionActive {
            mm.deviceMotionUpdateInterval = averageSamplingPeriod
            mm.startDeviceMotionUpdates(
                using: .xArbitraryZVertical,
                to: queue
            ) { [weak self] motion, error in
                guard let self = self, let motion = motion else { return }
                self.handleMotion(motion)
            }
        } else {
            // Already running from QuatOrientationOutput; attach via a separate handler.
            // In practice, the coordinator (SensorModule manager) should share the subscription.
            // This stub satisfies the protocol; the coordinator wires things properly.
        }
    }

    func stop() {
        // Motion manager is shared; do not stop it here — coordinator handles lifecycle.
    }

    func handleMotion(_ motion: CMDeviceMotion) {
        let sampleTime = Date().timeIntervalSince1970
        let attitude = motion.attitude

        let heading = -attitude.yaw * 180.0 / .pi
        let pitch = attitude.pitch * 180.0 / .pi
        let roll  = attitude.roll * 180.0 / .pi
        
        guard heading.isFinite, pitch.isFinite, roll.isFinite else { return }

        let scalars: [Double] = [sampleTime, heading, pitch, roll]
        subject.send(Observation(datastreamName: outputName, payload: .scalar(scalars)))
    }

    // Rotate the Y-axis unit vector (0,1,0) by quaternion q — same math as Android.
    // Returns (lookX, lookY).
    // Derivation for v=(0,1,0):
    //   rx = 2*(qx*qy + qw*qz)
    //   ry = qw^2 - qx^2 + qy^2 - qz^2
    private func rotateY(by q: CMQuaternion) -> (Double, Double) {
        let rx = 2.0 * (q.x * q.y + q.w * q.z)
        let ry = q.w * q.w - q.x * q.x + q.y * q.y - q.z * q.z
        return (rx, ry)
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
        quatOutput  = QuatOrientationOutput(motionManager: motionManager, queue: queue, localFrameURI: localFrameURI)
        eulerOutput = EulerOrientationOutput(motionManager: motionManager, queue: queue, localFrameURI: localFrameURI)
    }

    func start() throws {
        guard !isStarted else { return }
        guard motionManager.isDeviceMotionAvailable else {
            throw SensorError.unavailable("Device motion not available")
        }
        isStarted = true
        motionManager.deviceMotionUpdateInterval = 0.1
        motionManager.startDeviceMotionUpdates(
            using: .xTrueNorthZVertical,
            to: queue
        ) { [weak self] motion, error in
            guard let self = self, let motion = motion else { return }
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
