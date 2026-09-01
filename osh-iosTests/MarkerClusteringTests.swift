import Testing
import SwiftUI
import Foundation
import CoreLocation
import MapKit
@testable import osh_ios

// MARK: - MarkerClusteringTests
//
// Grouping markers that hide each other. The rules worth pinning down are the
// ones a user would notice going wrong: a group that does not dissolve when you
// zoom in, a group that shuffles when you pan by a hair, and this device
// disappearing inside a bubble.

// Main-actor because the types under test are: `DeviceLayer` is isolated
// outright and `SystemMapView`'s statics inherit it from `View`. Cheaper and
// truer than sprinkling `MainActor.assumeIsolated` over a dozen assertions.
@Suite("Marker clustering")
@MainActor
struct MarkerClusteringTests {

    // MARK: Fixtures

    private static func marker(_ id: String,
                               _ latitude: Double,
                               _ longitude: Double,
                               tint: Color = .blue,
                               activity: ActivityState = .live) -> SystemMapView.Marker {
        SystemMapView.Marker(id: id,
                             coordinate: CLLocationCoordinate2D(latitude: latitude,
                                                                longitude: longitude),
                             symbol: "circle",
                             tint: tint,
                             label: id,
                             activity: activity)
    }

    /// A cell of one degree, so the arithmetic in the tests is readable.
    private static let cell: (lat: Double, lon: Double) = (1, 1)

    private static func cluster(_ markers: [SystemMapView.Marker],
                                pinned: Set<String> = []) -> [MarkerClustering.Entry] {
        MarkerClustering.cluster(markers,
                                 cellLatitude: cell.lat,
                                 cellLongitude: cell.lon,
                                 pinned: pinned)
    }

    private static func clusters(_ entries: [MarkerClustering.Entry])
        -> [MarkerClustering.Cluster] {
        entries.compactMap { if case .cluster(let c) = $0 { return c } else { return nil } }
    }

    private static func singles(_ entries: [MarkerClustering.Entry])
        -> [SystemMapView.Marker] {
        entries.compactMap { if case .single(let m) = $0 { return m } else { return nil } }
    }

    // MARK: Grouping

    @Test("Markers further apart than a cell stay separate")
    func farApartStaySeparate() {
        let entries = Self.cluster([Self.marker("a", 0, 0),
                                    Self.marker("b", 10, 10)])
        #expect(Self.clusters(entries).isEmpty)
        #expect(Self.singles(entries).count == 2)
    }

    @Test("Markers inside a cell become one group")
    func nearbyGroup() {
        let entries = Self.cluster([Self.marker("a", 0, 0),
                                    Self.marker("b", 0.2, 0.2),
                                    Self.marker("c", -0.3, 0.1)])
        let grouped = Self.clusters(entries)
        #expect(grouped.count == 1)
        #expect(grouped.first?.count == 3)
        #expect(Self.singles(entries).isEmpty)
    }

    @Test("A group sits at its members' centroid")
    func centroid() {
        let entries = Self.cluster([Self.marker("a", 0, 0),
                                    Self.marker("b", 0.4, 0.8)])
        let group = Self.clusters(entries).first
        #expect(group?.coordinate.latitude == 0.2)
        #expect(group?.coordinate.longitude == 0.4)
    }

    /// The behaviour the whole feature is for: groups have to come apart as the
    /// camera zooms in, and the only thing that changes is the cell size.
    @Test("Zooming in dissolves a group")
    func zoomingDissolves() {
        let markers = [Self.marker("a", 0, 0), Self.marker("b", 0.2, 0.2)]

        let wide = MarkerClustering.cluster(markers, cellLatitude: 1, cellLongitude: 1)
        #expect(Self.clusters(wide).count == 1)

        let close = MarkerClustering.cluster(markers, cellLatitude: 0.01, cellLongitude: 0.01)
        #expect(Self.clusters(close).isEmpty)
        #expect(Self.singles(close).count == 2)
    }

    /// A grid would fail this: two markers a hair apart either side of a cell
    /// boundary would stay separate, and panning would make pins merge and
    /// split under the user's thumb.
    @Test("Neighbours are grouped wherever they fall, not by grid cell")
    func noGridBoundaryArtifact() {
        // Straddling every whole-degree boundary a naive grid would use.
        let entries = Self.cluster([Self.marker("a", 0.999, 0.999),
                                    Self.marker("b", 1.001, 1.001)])
        #expect(Self.clusters(entries).count == 1)
    }

    @Test("A lone marker is never wrapped in a group of one")
    func loneMarkerStaysSingle() {
        let entries = Self.cluster([Self.marker("only", 5, 5)])
        #expect(Self.clusters(entries).isEmpty)
        #expect(Self.singles(entries).map(\.id) == ["only"])
    }

    // MARK: Stability

    /// Input order must not change the output, or the map would reshuffle its
    /// bubbles every time a dictionary iterated differently.
    @Test("The same markers in any order produce the same groups")
    func orderIndependent() {
        let markers = [Self.marker("a", 0, 0),
                       Self.marker("b", 0.2, 0),
                       Self.marker("c", 9, 9)]

        let forward = Self.cluster(markers).map(\.id).sorted()
        let backward = Self.cluster(markers.reversed()).map(\.id).sorted()
        #expect(forward == backward)
    }

    @Test("A group's id names it stably across rebuilds")
    func stableIdentity() {
        let markers = [Self.marker("bravo", 0, 0), Self.marker("alpha", 0.1, 0.1)]
        #expect(Self.clusters(Self.cluster(markers)).first?.id == "cluster:alpha")
    }

    // MARK: Pinning

    /// Burying the user's own position inside a bubble labelled "6" hides the
    /// one marker they can always identify.
    @Test("A pinned marker is never grouped, even in a crowd")
    func pinnedMarkerStaysOut() {
        let entries = Self.cluster([Self.marker(DeviceLayer.markerId, 0, 0),
                                    Self.marker("a", 0.1, 0.1),
                                    Self.marker("b", 0.2, 0.2)],
                                   pinned: [DeviceLayer.markerId])

        #expect(Self.singles(entries).map(\.id) == [DeviceLayer.markerId])
        #expect(Self.clusters(entries).first?.count == 2)
    }

    // MARK: Coincident markers

    /// Two systems registered at the same installation point. No zoom level
    /// will ever separate them, so the map must offer a list instead of a zoom
    /// that goes nowhere.
    @Test("Markers on the identical coordinate are not separable")
    func coincidentIsNotSeparable() {
        let entries = Self.cluster([Self.marker("a", 34.7, -86.6),
                                    Self.marker("b", 34.7, -86.6)])
        #expect(Self.clusters(entries).first?.isSeparable == false)
    }

    @Test("Markers merely close together are separable by zooming")
    func nearbyIsSeparable() {
        let entries = Self.cluster([Self.marker("a", 34.7, -86.6),
                                    Self.marker("b", 34.7001, -86.6001)])
        let group = Self.clusters(entries).first
        #expect(group?.isSeparable == true)
        // The zoom target has a floor, so a pair two metres apart does not
        // frame itself into a blank tile.
        #expect((group?.boundingRegion.span.latitudeDelta ?? 0) >= 0.0008)
    }

    // MARK: Activity

    /// A group holding one live system is worth looking at, even if four dead
    /// ones outvote it.
    @Test("A group takes the freshest state among its members")
    func activityIsOptimistic() {
        let entries = Self.cluster([Self.marker("a", 0, 0, activity: .offline),
                                    Self.marker("b", 0.1, 0, activity: .stale),
                                    Self.marker("c", 0.2, 0, activity: .live)])
        #expect(Self.clusters(entries).first?.activity == .live)
    }

    // MARK: Cell size

    @Test("A cell is the separation distance expressed in degrees")
    func cellSizeFromSpan() {
        let cell = MarkerClustering.cellSize(
            span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 20),
            viewSize: CGSize(width: 400, height: 800),
            separation: 40)

        #expect(abs(cell.latitude - 0.5) < 1e-9)    // 10 × 40/800
        #expect(abs(cell.longitude - 2.0) < 1e-9)   // 20 × 40/400
    }

    /// One layout pass happens before the map has been measured, and grouping
    /// the world into a single bubble for that frame would be a visible flash.
    @Test("An unmeasured view groups nothing")
    func zeroSizedViewGroupsNothing() {
        let cell = MarkerClustering.cellSize(
            span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10),
            viewSize: .zero)
        #expect(cell.latitude == 0)

        let entries = MarkerClustering.cluster([Self.marker("a", 0, 0),
                                                Self.marker("b", 0, 0)],
                                               cellLatitude: 0, cellLongitude: 0)
        #expect(Self.clusters(entries).isEmpty)
        #expect(Self.singles(entries).count == 2)
    }

    // MARK: Summary

    @Test("The summary counts groups and the markers inside them")
    func summary() {
        let entries = Self.cluster([Self.marker("a", 0, 0),
                                    Self.marker("b", 0.1, 0),
                                    Self.marker("c", 20, 20),
                                    Self.marker("d", 20.1, 20),
                                    Self.marker("e", 20.2, 20),
                                    Self.marker("f", 50, 50)])
        let summary = MarkerClustering.summary(of: entries)

        #expect(summary.clusterCount == 2)
        #expect(summary.groupedMarkerCount == 5)
        #expect(!summary.isEmpty)
        #expect(MarkerClustering.summary(of: Self.cluster([Self.marker("x", 0, 0)])).isEmpty)
    }
}

// MARK: - MapFramingTests
//
// Where the camera opens. One system with an unset position must not decide
// that for the other twelve.

@Suite("Map framing")
@MainActor
struct MapFramingTests {

    private static func coordinate(_ latitude: Double,
                                   _ longitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The reference node's second Axis camera registers itself at (0, 0), and
    /// including it stretched the frame from Georgia to the Gulf of Guinea —
    /// every real marker in a corner and an ocean in the middle.
    @Test("Null Island does not get a vote on the camera")
    func nullIslandExcluded() {
        let framed = SystemMapView.framingCoordinates([
            Self.coordinate(0, 0),
            Self.coordinate(34.99, -85.32),
            Self.coordinate(35.01, -85.30)
        ])
        #expect(framed.count == 2)
        #expect(framed.allSatisfy { !SystemMapView.isNullIsland($0) })

        let region = SystemMapView.region(covering: framed)
        #expect(region.center.latitude > 34 && region.center.latitude < 36)
        #expect(region.center.longitude < -85 && region.center.longitude > -86)
    }

    /// A node where *everything* is unpositioned still has to draw something,
    /// and (0, 0) is then the only honest answer.
    @Test("A map of nothing but Null Island still frames on it")
    func onlyNullIsland() {
        let framed = SystemMapView.framingCoordinates([Self.coordinate(0, 0)])
        #expect(framed.count == 1)
    }

    @Test("A real fix near the equator is not mistaken for an unset one")
    func nearZeroIsKept() {
        // Off the coast of Ghana, a hundred metres from the origin but real.
        let real = Self.coordinate(0.001, 0.001)
        #expect(!SystemMapView.isNullIsland(real))
        #expect(SystemMapView.framingCoordinates([real, Self.coordinate(0, 0)]).count == 1)
    }

    @Test("Framing has a floor so one marker does not zoom to street level")
    func singleMarkerFloor() {
        let region = SystemMapView.region(covering: [Self.coordinate(34.7, -86.6)])
        #expect(region.span.latitudeDelta >= 0.01)
    }
}
