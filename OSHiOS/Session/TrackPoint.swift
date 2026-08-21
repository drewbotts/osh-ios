import Foundation
import CoreLocation

// MARK: - TrackPoint
//
// One position on a track. The map tab is written against this rather than
// against SensorSession so the same view can later draw a track fetched from an
// OSH node: a remote GPS datastream produces exactly the same ParsedObservation
// shape, and `from(_:accuracy:)` is the only piece that would need a sibling.

struct TrackPoint: Identifiable, Equatable, Sendable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let horizontalAccuracy: Double?
    let timestamp: Date

    init(id: UUID = UUID(),
         latitude: Double,
         longitude: Double,
         altitude: Double? = nil,
         horizontalAccuracy: Double? = nil,
         timestamp: Date) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Builds a point from a parsed observation of a Location record, using the
    /// paths the schema actually declares rather than fixed field names.
    static func from(_ observation: ParsedObservation,
                     paths: LocationPaths,
                     accuracy: Double?) -> TrackPoint? {
        guard let latitude = observation.values[paths.latitude]?.asDouble,
              let longitude = observation.values[paths.longitude]?.asDouble,
              latitude.isFinite, longitude.isFinite,
              CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude,
                                                                   longitude: longitude))
        else { return nil }

        let altitude = paths.altitude.flatMap { observation.values[$0]?.asDouble }
        return TrackPoint(latitude: latitude,
                          longitude: longitude,
                          altitude: altitude?.isFinite == true ? altitude : nil,
                          horizontalAccuracy: accuracy,
                          timestamp: observation.phenomenonTime)
    }
}
