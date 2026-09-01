import Foundation
import SwiftUI
import CoreLocation

// MARK: - DeviceLayer
//
// This device, expressed in the same terms as everything else on the map.
//
// The point of the common operating picture is that the phone is not a special
// case: it is a system with a position, a heading and an activity state, drawn
// with the same marker as an Axis camera. So its heading is read the way a
// node system's is — by classifying its own registered schema through
// DatastreamRoleInference and asking the resulting OrientationPaths — rather
// than by reaching into CMMotionManager behind the session's back.

@MainActor
enum DeviceLayer {

    /// The id the device marker is drawn under. Prefixed so it can never
    /// collide with a node resource id.
    static let markerId = "__this_device__"

    // MARK: Marker

    /// The device's marker, or nil when there is no fix to put it on.
    static func marker(session: SensorSession,
                       activity: ActivityState,
                       isFollowed: Bool) -> SystemMapView.Marker? {
        guard let fix = session.currentFix else { return nil }
        return SystemMapView.Marker(
            id: markerId,
            coordinate: fix.coordinate,
            symbol: isFollowed ? "location.north.line.fill" : "iphone.gen3",
            headingDegrees: heading(session: session),
            kind: .live,
            tint: .blue,
            label: "This Device",
            activity: activity)
    }

    /// The GPS uncertainty circle, when the fix reports one.
    static func accuracyCircle(session: SensorSession) -> SystemMapView.AccuracyCircle? {
        guard let fix = session.currentFix,
              let accuracy = fix.horizontalAccuracy, accuracy > 0 else { return nil }
        return SystemMapView.AccuracyCircle(center: fix.coordinate, radiusMeters: accuracy)
    }

    /// The recorded track, or an empty array when there is not enough of one to
    /// draw a line.
    static func track(session: SensorSession) -> [CLLocationCoordinate2D] {
        let coordinates = session.gpsTrack.map(\.coordinate)
        return coordinates.count >= 2 ? coordinates : []
    }

    // MARK: Heading

    /// The phone's compass heading, from whichever of its own outputs is an
    /// attitude. nil when orientation is switched off or has not produced a
    /// reading yet.
    static func heading(session: SensorSession) -> Double? {
        for state in session.sensorList {
            guard let paths = orientationPaths(for: state),
                  let latest = state.latest,
                  let heading = paths.heading(from: latest) else { continue }
            return heading
        }
        return nil
    }

    /// Role inference walks a schema, and the map asks for a heading every time
    /// a 10 Hz orientation reading lands. The schemas are fixed for the life of
    /// a run, so the answer is resolved once per output and kept.
    private static var pathCache: [String: OrientationPaths?] = [:]

    private static func orientationPaths(for state: SensorLiveState) -> OrientationPaths? {
        if let cached = pathCache[state.id] { return cached }

        var resolved: OrientationPaths?
        if case .orientation(let paths) = DatastreamRoleInference.role(
            schema: state.schema, datastreamName: state.displayName) {
            resolved = paths
        }
        pathCache[state.id] = resolved
        return resolved
    }
}
