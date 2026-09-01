import Testing
import Foundation
import CoreLocation
@testable import osh_ios

// MARK: - RemoteSystemTests
//
// The presentation model: where a marker's coordinates come from, which icon a
// system gets, and what a dashboard opens first.
//
// Built from fixture schemas wherever the node has one. The `.deployed` case is
// synthetic on purpose — no system on the reference node carries a geometry in
// its registration, so the one position source the viewer cannot test against
// that node is the one it has to test hardest here.

@Suite("Remote system presentation")
struct RemoteSystemTests {

    // MARK: Building blocks

    private static func datastream(_ slug: FixtureLoader.Slug,
                                   id: String,
                                   name: String? = nil) throws -> RemoteDatastream {
        let data: Data
        if let binary = FixtureLoader.data(slug, "schema-binary.json") {
            data = binary
        } else {
            data = try FixtureLoader.requiredData(slug, "schema-json.json")
        }
        let schema = try SWESchemaDecoder.decode(data)
        let summary = DatastreamSummary(id: id, name: name ?? slug.rawValue)
        let decoder = try DatastreamDecoder(datastreamId: id, schema: schema)
        return RemoteDatastream(summary: summary, schema: schema, decoder: decoder)
    }

    private static func system(id: String = "sys",
                               name: String = "System",
                               datastreams: [RemoteDatastream],
                               fixedLocation: CLLocationCoordinate2D? = nil,
                               subsystems: [SystemSummary] = [],
                               controlStreams: [RemoteControlStream] = []) -> RemoteSystem {
        RemoteSystem(summary: SystemSummary(id: id, name: name),
                     subsystems: subsystems,
                     datastreams: datastreams,
                     controlStreams: controlStreams,
                     fixedLocation: fixedLocation)
    }

    // MARK: Position source

    @Test("A location datastream makes the position live")
    func livePosition() throws {
        let system = Self.system(datastreams: [try Self.datastream(.gps, id: "gps")])
        #expect(system.positionKind == .live)
        #expect(system.hasPosition)
    }

    @Test("A settings record's embedded position makes it reported")
    func reportedPosition() throws {
        let system = Self.system(datastreams: [
            try Self.datastream(.krakenSettings, id: "settings",
                                name: "KrakenSDR - Current Applicable Settings")
        ])
        #expect(system.positionKind == .reported)
        #expect(system.reportedPositionDatastreams.count == 1)
    }

    /// A weather station whose only position is in its registration still
    /// belongs on the map, as a static "installed here" pin.
    @Test("A system resource geometry alone makes it deployed")
    func deployedPosition() throws {
        let system = Self.system(
            datastreams: [try Self.datastream(.weather, id: "weather",
                                              name: "Tempest - Observation")],
            fixedLocation: CLLocationCoordinate2D(latitude: 34.72, longitude: -86.58))
        #expect(system.positionKind == .deployed)
        #expect(system.hasPosition)
    }

    @Test("A system nothing locates has no position at all")
    func noPosition() throws {
        let system = Self.system(datastreams: [
            try Self.datastream(.weather, id: "weather", name: "Tempest - Observation")
        ])
        #expect(system.positionKind == nil)
        #expect(!system.hasPosition)
    }

    /// Live beats reported beats deployed. A KrakenSDR that also published a
    /// GPS output should be tracked, not pinned where it was installed.
    @Test("The best position source wins")
    func positionPriority() throws {
        let all = Self.system(
            datastreams: [try Self.datastream(.krakenSettings, id: "settings"),
                          try Self.datastream(.gps, id: "gps")],
            fixedLocation: CLLocationCoordinate2D(latitude: 1, longitude: 2))
        #expect(all.positionKind == .live)

        let reportedAndDeployed = Self.system(
            datastreams: [try Self.datastream(.krakenSettings, id: "settings")],
            fixedLocation: CLLocationCoordinate2D(latitude: 1, longitude: 2))
        #expect(reportedAndDeployed.positionKind == .reported)
    }

    /// KrakenSDR states its position twice — bare on every LOB and beside the
    /// array heading in its settings — and only one of those rotates a marker.
    @Test("A reported position that carries a heading is preferred")
    func reportedPositionWithHeadingWins() throws {
        let doaFirst = Self.system(datastreams: [
            try Self.datastream(.krakenDOA, id: "doa", name: "KrakenSDR - DoA"),
            try Self.datastream(.krakenSettings, id: "settings",
                                name: "KrakenSDR - Current Applicable Settings")
        ])
        let best = try #require(doaFirst.reportedPositionDatastreams.first)
        #expect(best.id == "settings")
        #expect(best.embeddedPosition?.headingPath?.description == "/stationConfig/heading")
    }

    // MARK: Character

    @Test("A camera is a camera whatever else it publishes")
    func videoWinsPrimaryRole() throws {
        let system = Self.system(datastreams: [
            try Self.datastream(.weather, id: "status"),
            try Self.datastream(.videoMJPEG, id: "video")
        ])
        #expect(system.primaryRole == .video(compression: "JPEG"))
        #expect(SystemGlyph.symbol(for: system) == "video.fill")
    }

    /// A Tempest is a `.timeseries` exactly as a battery monitor is. On a map
    /// full of pins the icon is what tells them apart.
    @Test("A weather station gets the weather glyph, not the timeseries one")
    func weatherGlyphSpecialCase() throws {
        let system = Self.system(datastreams: [
            try Self.datastream(.weather, id: "weather", name: "Tempest - Observation")
        ])
        #expect(system.primaryRole == .timeseries)
        #expect(SystemGlyph.symbol(for: .timeseries) == "chart.xyaxis.line")
        #expect(SystemGlyph.symbol(for: system) == "cloud.sun.fill")
    }

    @Test("Every role has a glyph")
    func everyRoleHasAGlyph() {
        let roles: [DatastreamRole] = [
            .location(LocationPaths(latitude: FieldPath("/lat"),
                                    longitude: FieldPath("/lon"),
                                    altitude: nil), headingPath: nil),
            .orientation(OrientationPaths(kind: .euler(heading: FieldPath("/h"),
                                                       pitch: nil, roll: nil))),
            .bearing(BearingPaths(angle: FieldPath("/a"), quality: nil)),
            .video(compression: "JPEG"),
            .chart(ChartPaths(series: [FieldPath("/s")], xAxis: nil)),
            .timeseries, .status, .generic
        ]
        for role in roles {
            #expect(!SystemGlyph.symbol(for: role).isEmpty)
            #expect(!role.label.isEmpty)
        }
    }

    // MARK: Ordering

    /// A direction-finding station reads top-down as "here is the station, here
    /// is what it heard": the settings card carries the position and the array
    /// heading, and the LOB dial is meaningless without them.
    @Test("A dashboard leads with status, then bearing")
    func dashboardOrdering() throws {
        let ordered = DashboardOrder.order([
            try Self.datastream(.spectrumArray, id: "spectrum"),
            try Self.datastream(.krakenDOA, id: "doa"),
            try Self.datastream(.krakenSettings, id: "settings")
        ])
        #expect(ordered.map(\.id) == ["settings", "doa", "spectrum"])
    }

    /// The dashboard opens what says most about the system. Video is excluded
    /// entirely — bandwidth is the scarce thing, and a camera is the one stream
    /// a user can be trusted to ask for.
    @Test("The default stream selection ranks position and bearing first and drops video")
    func defaultSelectionOrder() throws {
        let system = Self.system(datastreams: [
            try Self.datastream(.videoMJPEG, id: "video"),
            try Self.datastream(.spectrumArray, id: "spectrum"),
            try Self.datastream(.krakenSettings, id: "settings"),
            try Self.datastream(.krakenDOA, id: "doa"),
            try Self.datastream(.gps, id: "gps")
        ])
        let ordered = system.streamsByViewingPriority.map(\.id)
        #expect(ordered.first == "gps")
        #expect(ordered.firstIndex(of: "doa")! < ordered.firstIndex(of: "spectrum")!)
        // A settings stream ranks above a spectrum only because it carries a
        // position; without that it would be the least interesting thing here.
        #expect(ordered.firstIndex(of: "settings")! < ordered.firstIndex(of: "spectrum")!)
    }

    // MARK: Schema failures

    /// One unreadable schema must cost that datastream and nothing else.
    @Test("A schema-failed datastream is still listed, as generic, with its error")
    func schemaFailureIsContained() throws {
        let broken = RemoteDatastream(summary: DatastreamSummary(id: "bad", name: "Bad"),
                                      schemaError: "unresolved reference #nope")
        let system = Self.system(datastreams: [try Self.datastream(.gps, id: "gps"), broken])

        #expect(system.datastreams.count == 2)
        #expect(broken.role == .generic)
        #expect(broken.decoder == nil)
        #expect(broken.schemaError != nil)
        #expect(broken.embeddedPosition == nil)
        // The good one still decides what the system is.
        #expect(system.positionKind == .live)
    }
}
