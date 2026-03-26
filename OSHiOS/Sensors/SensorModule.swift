import Foundation
import Combine

// MARK: - SensorModule protocol
//
// Swift equivalent of IAndroidOutput / AbstractSensorOutput.
// All sensor outputs conform to this protocol.

// Default no-op so non-video sensors don't need to implement configure().
extension SensorModule {
    func configure() throws {}
}

protocol SensorModule: AnyObject {
    /// Unique name used to match this output to its registered datastream.
    var outputName: String { get }

    /// SWE DataRecord describing the observation schema.
    var recordDescription: DataRecord { get }

    /// Preferred binary encoding for the schema.
    var recommendedEncoding: BinaryEncoding { get }

    /// Nominal seconds between records (1/frameRate for video, 1.0 for GPS, etc.)
    var averageSamplingPeriod: Double { get }

    /// Combine publisher that emits one Observation per sensor reading.
    var publisher: AnyPublisher<Observation, Never> { get }

    /// Optional hardware setup called before datastream registration.
    /// Override in outputs that need actual hardware info (e.g. real camera
    /// resolution) to produce the correct schema. Default: no-op.
    func configure() throws

    /// Begin capturing and emitting observations.
    func start() throws

    /// Stop capturing.
    func stop()
}
