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

final class GPSOutput: NSObject, SensorModule {
    let outputName: String
    let recordDescription: DataRecord
    let recommendedEncoding: BinaryEncoding
    let averageSamplingPeriod: Double = 1.0

    private let subject = PassthroughSubject<Observation, Never>()
    var publisher: AnyPublisher<Observation, Never> { subject.eraseToAnyPublisher() }

    private let locationManager: CLLocationManager
    private let localFrameURI: String

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
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    func stop() {
        locationManager.stopUpdatingLocation()
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
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Non-fatal; just log.  Connectivity / permission issues surface here.
        print("[GPSOutput] CLLocationManager error: \(error.localizedDescription)")
    }
}
