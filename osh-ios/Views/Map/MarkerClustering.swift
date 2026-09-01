import Foundation
import CoreLocation
import MapKit

// MARK: - MarkerClustering
//
// Grouping markers that are too close together to tell apart.
//
// SwiftUI's Map has no clustering on this deployment target, and the map's
// answer until now was decimation: draw the newest hundred and say so in the
// legend. That is honest but it is still the wrong answer — in a busy anchorage
// the pin you can see is hiding four you cannot, and dropping the rest does not
// make the survivors legible.
//
// So markers within a thumb's width of each other become one bubble carrying a
// count, and the grouping dissolves as you zoom in, because the cell size is
// derived from the camera's own span. Nothing here knows about zoom *levels*:
// a cell is a fixed number of points on screen and the arithmetic falls out of
// the region.
//
// Deliberately free of SwiftUI and of any camera. Its inputs are markers, a
// span and a view size; its output is a list of things to draw. That is what
// makes it testable without a map.

enum MarkerClustering {

    // MARK: Configuration

    /// How far apart two markers must be, in points, to stay separate.
    ///
    /// A marker disc is 30pt and a comfortable touch target is 44, so anything
    /// closer than this is a pin the user cannot single out by tapping — which
    /// is the whole definition of "hiding" another marker.
    static let separationPoints: CGFloat = 52

    /// Below this the two coordinates are the same place: roughly a centimetre
    /// of latitude. A cluster whose members are all this close can never be
    /// separated by zooming, however far in you go.
    static let coincidentDegrees: CLLocationDegrees = 1e-7

    // MARK: Output

    /// One drawn annotation: either a marker on its own or a group of them.
    enum Entry: Identifiable {
        case single(SystemMapView.Marker)
        case cluster(Cluster)

        var id: String {
            switch self {
            case .single(let marker):   return marker.id
            case .cluster(let cluster): return cluster.id
            }
        }

        var coordinate: CLLocationCoordinate2D {
            switch self {
            case .single(let marker):   return marker.coordinate
            case .cluster(let cluster): return cluster.coordinate
            }
        }
    }

    /// Several markers drawn as one.
    struct Cluster: Identifiable, Equatable {

        /// Stable across rebuilds: every marker belongs to exactly one cluster,
        /// so the lowest member id can only name this one. A hash of all the
        /// ids would be stabler still and is not worth the string.
        let id: String
        /// The centroid — where the bubble sits.
        let coordinate: CLLocationCoordinate2D
        let members: [SystemMapView.Marker]
        /// The region that contains every member, for the zoom-in tap.
        let boundingRegion: MKCoordinateRegion
        /// False when every member is at the same coordinate, in which case
        /// zooming will never pull them apart and the caller must list them
        /// instead.
        let isSeparable: Bool

        var count: Int { members.count }

        /// The freshest state any member is in.
        ///
        /// Optimistic on purpose: a group containing one live system is a group
        /// worth looking at, and painting it red because four dead ones outvote
        /// the live one would bury the only interesting thing in it.
        var activity: ActivityState {
            members.map(\.activity).min { $0.sortRank < $1.sortRank } ?? .offline
        }

        static func == (lhs: Cluster, rhs: Cluster) -> Bool {
            lhs.id == rhs.id
                && lhs.count == rhs.count
                && lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
                && lhs.activity == rhs.activity
        }
    }

    /// How much grouping happened, for a legend that would otherwise claim the
    /// map is showing more pins than it is.
    struct Summary: Equatable {
        var clusterCount = 0
        /// How many markers those clusters stand for.
        var groupedMarkerCount = 0

        static let none = Summary()
        var isEmpty: Bool { clusterCount == 0 }
    }

    // MARK: Cell size

    /// How many degrees wide and tall one cluster cell is at this camera.
    ///
    /// Screen space, not ground distance. SwiftUI's Map is a Mercator
    /// projection, so over one screenful both axes are near enough linear in
    /// degrees — which means the ratio of the span to the view's size in points
    /// is all the arithmetic there is, and no cosine correction is wanted. A
    /// cosine would be right for metres and wrong for pixels.
    static func cellSize(span: MKCoordinateSpan,
                         viewSize: CGSize,
                         separation: CGFloat = separationPoints)
        -> (latitude: CLLocationDegrees, longitude: CLLocationDegrees) {

        // A zero-sized view happens for one layout pass before the map has been
        // measured. Falling back to a whole-screen cell would group the world
        // into one bubble for that frame, so nothing is grouped instead.
        guard viewSize.width > 0, viewSize.height > 0 else { return (0, 0) }
        return (span.latitudeDelta * Double(separation / viewSize.height),
                span.longitudeDelta * Double(separation / viewSize.width))
    }

    // MARK: Clustering

    /// Groups markers that sit within one cell of each other.
    ///
    /// Greedy rather than a grid. A grid is one line shorter and has an
    /// artifact the user sees immediately: two markers a point apart that
    /// straddle a cell boundary stay separate, so pins merge and split as you
    /// pan by a hair. Seeding a cluster from each unassigned marker and
    /// absorbing its neighbours has no boundaries to straddle, and at the
    /// hundreds of markers a map can hold the quadratic cost is nothing.
    ///
    /// - Parameter pinned: ids that are never grouped. This device is the only
    ///   one: burying the user's own position inside a bubble labelled "6"
    ///   would hide the one marker they can always identify.
    static func cluster(_ markers: [SystemMapView.Marker],
                        cellLatitude: CLLocationDegrees,
                        cellLongitude: CLLocationDegrees,
                        pinned: Set<String> = []) -> [Entry] {

        guard cellLatitude > 0, cellLongitude > 0 else { return markers.map(Entry.single) }

        // Sorted so the same input always seeds the same clusters. Without it
        // the grouping would shuffle whenever a dictionary iterated differently.
        let candidates = markers.filter { !pinned.contains($0.id) }
            .sorted { $0.id < $1.id }

        var entries: [Entry] = markers.filter { pinned.contains($0.id) }.map(Entry.single)
        var taken = Set<Int>()

        for index in candidates.indices where !taken.contains(index) {
            let seed = candidates[index]
            taken.insert(index)

            var group = [seed]
            for other in candidates.indices where !taken.contains(other) {
                let candidate = candidates[other]
                guard abs(candidate.coordinate.latitude - seed.coordinate.latitude) <= cellLatitude,
                      abs(candidate.coordinate.longitude - seed.coordinate.longitude) <= cellLongitude
                else { continue }
                taken.insert(other)
                group.append(candidate)
            }

            entries.append(group.count == 1 ? .single(seed) : .cluster(makeCluster(group)))
        }
        return entries
    }

    /// Convenience over `cluster(_:cellLatitude:cellLongitude:pinned:)`.
    static func cluster(_ markers: [SystemMapView.Marker],
                        span: MKCoordinateSpan,
                        viewSize: CGSize,
                        pinned: Set<String> = []) -> [Entry] {
        let cell = cellSize(span: span, viewSize: viewSize)
        return cluster(markers,
                       cellLatitude: cell.latitude,
                       cellLongitude: cell.longitude,
                       pinned: pinned)
    }

    /// How the entries came out, for the legend.
    static func summary(of entries: [Entry]) -> Summary {
        var summary = Summary()
        for case .cluster(let cluster) in entries {
            summary.clusterCount += 1
            summary.groupedMarkerCount += cluster.count
        }
        return summary
    }

    // MARK: Building one cluster

    private static func makeCluster(_ members: [SystemMapView.Marker]) -> Cluster {
        let latitudes = members.map(\.coordinate.latitude)
        let longitudes = members.map(\.coordinate.longitude)

        let minLatitude = latitudes.min() ?? 0, maxLatitude = latitudes.max() ?? 0
        let minLongitude = longitudes.min() ?? 0, maxLongitude = longitudes.max() ?? 0

        let latitudeExtent = maxLatitude - minLatitude
        let longitudeExtent = maxLongitude - minLongitude

        let centre = CLLocationCoordinate2D(
            latitude: latitudes.reduce(0, +) / Double(members.count),
            longitude: longitudes.reduce(0, +) / Double(members.count))

        // Margin so the members land inside the frame rather than on its edge,
        // and a floor so a two-metre-apart pair does not zoom to a blank tile.
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2,
                                           longitude: (minLongitude + maxLongitude) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(latitudeExtent * 2.2, 0.0008),
                                   longitudeDelta: max(longitudeExtent * 2.2, 0.0008)))

        return Cluster(id: "cluster:" + (members.map(\.id).min() ?? ""),
                       coordinate: centre,
                       members: members,
                       boundingRegion: region,
                       isSeparable: latitudeExtent > coincidentDegrees
                           || longitudeExtent > coincidentDegrees)
    }
}
