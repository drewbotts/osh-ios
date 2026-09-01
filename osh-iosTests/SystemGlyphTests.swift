import Testing
import SwiftUI
@testable import osh_ios

// MARK: - SystemGlyphTests
//
// The glyph and tint tables, checked for completeness.
//
// The point is not the specific colours — it is that adding a role cannot
// silently produce a system that draws grey on the map, grey in the list and
// grey on the video wall because one table was updated and the other was not.

@Suite("System glyph")
struct SystemGlyphTests {

    /// Every role, spelled out rather than derived. A `CaseIterable` conformance
    /// is impossible here — three cases carry associated values — so this list
    /// is the thing that has to be updated when a role is added, and the tests
    /// below are what make forgetting it a failure.
    static let allRoles: [DatastreamRole] = [
        .target(TargetPaths(location: LocationPaths(latitude: FieldPath(components: ["lat"]),
                                                    longitude: FieldPath(components: ["lon"]),
                                                    altitude: nil),
                            range: nil, azimuth: nil, elevation: nil, sourceIdPath: nil)),
        .location(LocationPaths(latitude: FieldPath(components: ["lat"]),
                                longitude: FieldPath(components: ["lon"]),
                                altitude: nil),
                  headingPath: nil),
        .orientation(OrientationPaths(kind: .euler(heading: FieldPath(components: ["h"]),
                                                   pitch: nil, roll: nil))),
        .bearing(BearingPaths(angle: FieldPath(components: ["a"]), quality: nil)),
        .video(compression: "JPEG"),
        .chart(ChartPaths(series: [], xAxis: nil)),
        .timeseries,
        .status,
        .generic
    ]

    @Test("Every role has a glyph")
    func everyRoleHasGlyph() {
        for role in Self.allRoles {
            #expect(!SystemGlyph.symbol(for: role).isEmpty, "no glyph for \(role.label)")
        }
    }

    @Test("Every role has a tint, and no two share one")
    func everyRoleHasDistinctTint() {
        let tints = Self.allRoles.map { SystemGlyph.tint(for: $0) }
        #expect(tints.count == Set(tints.map(String.init(describing:))).count,
                "two roles share a tint: \(tints)")
    }

    /// The table itself, so a change to it is a deliberate edit rather than a
    /// side effect of touching the marker.
    @Test("The tint table is the documented one")
    func tintTable() {
        #expect(SystemGlyph.tint(for: .video(compression: nil)) == .indigo)
        #expect(SystemGlyph.tint(for: Self.allRoles[0]) == .red, "targets are red")
        #expect(SystemGlyph.tint(for: .timeseries) == .green)
        #expect(SystemGlyph.tint(for: .status) == .gray)
        #expect(SystemGlyph.tint(for: .generic) == .secondary)
    }

    @Test("Every role label is unique, since badges and logs are read by it")
    func labelsAreUnique() {
        let labels = Self.allRoles.map(\.label)
        #expect(labels.count == Set(labels).count)
    }
}
