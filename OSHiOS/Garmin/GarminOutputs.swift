import Foundation
import Combine

// MARK: - GarminHeartRateOutput

final class GarminHeartRateOutput: SensorModule {
    let outputName = "garmin_heart_rate"
    let recordDescription: DataRecord
    let recommendedEncoding: BinaryEncoding
    let averageSamplingPeriod: Double = 1.0   // ~1 Hz from wearable

    private let subject = PassthroughSubject<Observation, Never>()
    var publisher: AnyPublisher<Observation, Never> { subject.eraseToAnyPublisher() }

    // Source publisher injected at init so start() needs no @MainActor access
    private let source: PassthroughSubject<[Double], Never>
    private var cancellable: AnyCancellable?

    init(source: PassthroughSubject<[Double], Never>) {
        self.source = source
        self.recordDescription  = GarminSWESchemas.heartRateRecord(name: "garmin_heart_rate")
        self.recommendedEncoding = GarminSWESchemas.heartRateEncoding()
    }

    func start() throws {
        cancellable = source
            .receive(on: RunLoop.main)
            .sink { [weak self] values in
                guard let self else { return }
                self.subject.send(Observation(datastreamName: self.outputName,
                                              payload: .scalar(values)))
            }
    }

    func stop() {
        cancellable = nil
    }
}

// MARK: - GarminStressOutput

final class GarminStressOutput: SensorModule {
    let outputName = "garmin_stress"
    let recordDescription: DataRecord
    let recommendedEncoding: BinaryEncoding
    let averageSamplingPeriod: Double = 3.0   // stress updates roughly every few seconds

    private let subject = PassthroughSubject<Observation, Never>()
    var publisher: AnyPublisher<Observation, Never> { subject.eraseToAnyPublisher() }

    private let source: PassthroughSubject<[Double], Never>
    private var cancellable: AnyCancellable?

    init(source: PassthroughSubject<[Double], Never>) {
        self.source = source
        self.recordDescription   = GarminSWESchemas.stressRecord(name: "garmin_stress")
        self.recommendedEncoding = GarminSWESchemas.stressEncoding()
    }

    func start() throws {
        cancellable = source
            .receive(on: RunLoop.main)
            .sink { [weak self] values in
                guard let self else { return }
                self.subject.send(Observation(datastreamName: self.outputName,
                                              payload: .scalar(values)))
            }
    }

    func stop() {
        cancellable = nil
    }
}

// MARK: - GarminRespirationOutput

final class GarminRespirationOutput: SensorModule {
    let outputName = "garmin_respiration"
    let recordDescription: DataRecord
    let recommendedEncoding: BinaryEncoding
    let averageSamplingPeriod: Double = 4.0   // ~0.25 Hz

    private let subject = PassthroughSubject<Observation, Never>()
    var publisher: AnyPublisher<Observation, Never> { subject.eraseToAnyPublisher() }

    private let source: PassthroughSubject<[Double], Never>
    private var cancellable: AnyCancellable?

    init(source: PassthroughSubject<[Double], Never>) {
        self.source = source
        self.recordDescription   = GarminSWESchemas.respirationRecord(name: "garmin_respiration")
        self.recommendedEncoding = GarminSWESchemas.respirationEncoding()
    }

    func start() throws {
        cancellable = source
            .receive(on: RunLoop.main)
            .sink { [weak self] values in
                guard let self else { return }
                self.subject.send(Observation(datastreamName: self.outputName,
                                              payload: .scalar(values)))
            }
    }

    func stop() {
        cancellable = nil
    }
}

// MARK: - GarminAccelerometerOutput

final class GarminAccelerometerOutput: SensorModule {
    let outputName = "garmin_accelerometer"
    let recordDescription: DataRecord
    let recommendedEncoding: BinaryEncoding
    let averageSamplingPeriod: Double = 0.02  // ~50 Hz

    private let subject = PassthroughSubject<Observation, Never>()
    var publisher: AnyPublisher<Observation, Never> { subject.eraseToAnyPublisher() }

    private let source: PassthroughSubject<[Double], Never>
    private var cancellable: AnyCancellable?

    init(source: PassthroughSubject<[Double], Never>,
         localFrameURI: String) {
        self.source = source
        self.recordDescription   = GarminSWESchemas.accelerometerRecord(
            name: "garmin_accelerometer",
            localFrameURI: localFrameURI
        )
        self.recommendedEncoding = GarminSWESchemas.accelerometerEncoding()
    }

    func start() throws {
        cancellable = source
            .receive(on: RunLoop.main)
            .sink { [weak self] values in
                guard let self else { return }
                self.subject.send(Observation(datastreamName: self.outputName,
                                              payload: .scalar(values)))
            }
    }

    func stop() {
        cancellable = nil
    }
}
