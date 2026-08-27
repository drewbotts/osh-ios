import Foundation
import CoreLocation

// MARK: - BearingGeometry
//
// Where a line of bearing ends.
//
// The endpoint is computed on the sphere, never on the screen. A LOB is an
// angle from true north at a point on the Earth, and drawing it as a rotated
// line in view space is only correct on the equator at one zoom level: at 60°
// north a Mercator projection stretches longitude by a factor of two, so a
// screen-space 45° line points at 63° on the ground. Two kilometres of error at
// two kilometres of length.

enum BearingGeometry {

    /// Mean Earth radius (IUGG), in metres.
    static let earthRadius = 6_371_008.8

    /// The point `distanceMeters` away from `origin` along `bearingDegrees`,
    /// measured clockwise from true north.
    ///
    /// The standard spherical direct problem:
    ///
    ///     φ₂ = asin(sin φ₁ · cos δ + cos φ₁ · sin δ · cos θ)
    ///     λ₂ = λ₁ + atan2(sin θ · sin δ · cos φ₁, cos δ − sin φ₁ · sin φ₂)
    ///
    /// with δ the angular distance d/R. Accurate to a few metres over the
    /// couple of kilometres a LOB is drawn for, which is far inside the
    /// uncertainty of the bearing itself.
    static func destination(from origin: CLLocationCoordinate2D,
                            bearingDegrees: Double,
                            distanceMeters: Double) -> CLLocationCoordinate2D {

        let angularDistance = distanceMeters / earthRadius
        let bearing = bearingDegrees * .pi / 180
        let latitude = origin.latitude * .pi / 180
        let longitude = origin.longitude * .pi / 180

        let destinationLatitude = asin(
            sin(latitude) * cos(angularDistance)
                + cos(latitude) * sin(angularDistance) * cos(bearing))

        let destinationLongitude = longitude + atan2(
            sin(bearing) * sin(angularDistance) * cos(latitude),
            cos(angularDistance) - sin(latitude) * sin(destinationLatitude))

        return CLLocationCoordinate2D(
            latitude: destinationLatitude * 180 / .pi,
            // Wrapping matters at the antimeridian, where an unwrapped value
            // draws a line the long way round the world.
            longitude: ((destinationLongitude * 180 / .pi) + 540)
                .truncatingRemainder(dividingBy: 360) - 180)
    }
}

// MARK: - BearingStyle

/// The numbers behind a drawn LOB. One place, because "how long is the line"
/// gets asked by the map, the dashboard's map card and the marker sheet.
enum BearingStyle {

    /// How far the line is drawn. A LOB has no range — the emitter could be a
    /// kilometre away or fifty — so this is a legibility choice, not a claim.
    static let lineLength: Double = 2000

    static let lineWidth: Double = 3

    /// A line older than this fades, but is never removed: direction finding
    /// emits only on detection, and "the last thing we heard, an hour ago" is
    /// the answer to the question the user is asking.
    static let staleAfter: TimeInterval = 60

    static let staleOpacity: Double = 0.3
    static let freshOpacity: Double = 0.85

    /// How long the return to full opacity takes when a new LOB lands.
    static let refreshDuration: Double = 0.3

    /// A detection at or above this fraction of the rolling maximum quality
    /// gets a wider, softer line behind it.
    static let strongQualityFraction: Double = 0.7

    /// Opacity for a line last updated at `timestamp`.
    static func opacity(at timestamp: Date, now: Date = Date()) -> Double {
        now.timeIntervalSince(timestamp) > staleAfter ? staleOpacity : freshOpacity
    }
}
