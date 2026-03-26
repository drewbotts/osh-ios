import Foundation
import CoreMotion
import Combine

// MARK: - BarometerOutput
//
// Reads atmospheric pressure and relative altitude from CMAltimeter.
//
// SWE schema field order (must match values array order exactly):
//   0: time             — Unix epoch seconds → ISO 8601 string
//   1: pressure         — hPa (altitudeData.pressure is kPa × 10)
//   2: relativeAltitude — metres (relative to start of session)
//
// Update rate: driven by CMAltimeter (~1 Hz on device, unavailable on simulator).
// If the hardware is absent, start() returns without throwing so the session
// continues with whatever other sensors are available.

final class BarometerOutput: SensorModule {
    let outputName = "barometer"
    let recordDescription: DataRecord
    let recommendedEncoding: BinaryEncoding
    let averageSamplingPeriod: Double = 1.0

    private let subject = PassthroughSubject<Observation, Never>()
    var publisher: AnyPublisher<Observation, Never> { subject.eraseToAnyPublisher() }

    private let altimeter = CMAltimeter()

    // MARK: Init

    init() {
        self.recordDescription = DataRecord(
            definition: "http://sensorml.com/ont/swe/property/AtmosphericPressure",
            label: "Barometer",
            name: "barometer",
            fields: [
                DataField(name: "time", component: TimeStamp(
                    definition: "http://www.opengis.net/def/property/OGC/0/SamplingTime",
                    label: "Sampling Time",
                    refFrame: "http://www.opengis.net/def/trs/BIPM/0/UTC",
                    uomHref: "http://www.opengis.net/def/uom/ISO-8601/0/Gregorian"
                )),
                DataField(name: "pressure", component: Quantity(
                    definition: "http://sensorml.com/ont/swe/property/AtmosphericPressure",
                    label: "Atmospheric Pressure",
                    uom: "hPa",
                    dataType: .double
                )),
                DataField(name: "relativeAltitude", component: Quantity(
                    definition: "http://sensorml.com/ont/swe/property/AltitudeAboveEllipsoid",
                    label: "Relative Altitude",
                    uom: "m",
                    dataType: .double
                ))
            ]
        )
        self.recommendedEncoding = BinaryEncoding(fields: [
            BinaryFieldEncoding(ref: "/time",             type: .scalar(.double)),
            BinaryFieldEncoding(ref: "/pressure",         type: .scalar(.double)),
            BinaryFieldEncoding(ref: "/relativeAltitude", type: .scalar(.double))
        ])
    }

    // MARK: SensorModule

    func start() throws {
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            print("[BarometerOutput] Relative altitude not available on this device")
            return
        }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self, let data else { return }
            let scalars: [Double] = [
                Date().timeIntervalSince1970,
                data.pressure.doubleValue * 10.0, // kPa → hPa
                data.relativeAltitude.doubleValue
            ]
            self.subject.send(Observation(datastreamName: self.outputName,
                                          payload: .scalar(scalars)))
        }
    }

    func stop() {
        altimeter.stopRelativeAltitudeUpdates()
    }
}
