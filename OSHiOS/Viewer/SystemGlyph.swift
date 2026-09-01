import Foundation
import SwiftUI

// MARK: - SystemGlyph
//
// One table, three consumers: the map's markers, the browser's rows and the
// dashboard's header. Splitting them was the obvious thing and the wrong one —
// a weather station that is a cloud on the map and a box in the list reads as
// two different systems.

enum SystemGlyph {

    /// SF Symbol for a role.
    static func symbol(for role: DatastreamRole) -> String {
        switch role {
        case .video:       return "video.fill"
        case .target:      return "scope"
        case .location:    return "location.north.line.fill"
        case .orientation: return "gyroscope"
        case .bearing:     return "dot.radiowaves.left.and.right"
        case .chart:       return "waveform.path"
        case .timeseries:  return "chart.xyaxis.line"
        case .status:      return "gearshape.2"
        case .generic:     return "shippingbox"
        }
    }

    /// The glyph a *target* is drawn with — the point a `.target` stream
    /// designates, not the system that designated it.
    ///
    /// Separate from `symbol(for:)` because one `.target` datastream produces
    /// two things on the map with different meanings: a scope on the range
    /// finder's own card and row, and a crosshair out where it is looking.
    static let targetMarkerSymbol = "plus.viewfinder"

    // MARK: Tints

    /// The colour a role is drawn in, everywhere it is drawn.
    ///
    /// Lived in the map's annotation code until the marker redesign, the
    /// systems list and the video wall all needed it. One table is the whole
    /// point: a camera that is indigo on the map and purple in the list reads
    /// as two kinds of thing.
    ///
    /// Exhaustive by construction — a `switch` with no `default`, so adding a
    /// role is a compile error here rather than a system that silently draws
    /// grey.
    static func tint(for role: DatastreamRole) -> Color {
        switch role {
        case .video:       return .indigo
        case .target:      return .red
        case .location:    return .blue
        case .orientation: return .teal
        case .bearing:     return .orange
        case .chart:       return .purple
        case .timeseries:  return .green
        case .status:      return .gray
        case .generic:     return .secondary
        }
    }

    /// The colour a whole system is drawn in.
    ///
    /// Weather takes teal for the same reason it takes a cloud glyph: a Tempest
    /// station is a `.timeseries` like a battery monitor is, and only one of
    /// them should look like weather on a map.
    static func tint(for system: RemoteSystem) -> Color {
        if isWeather(system), weakRoles.contains(system.primaryRole.label) {
            return .teal
        }
        return tint(for: system.primaryRole)
    }

    /// SF Symbol for a whole system.
    ///
    /// Weather is special-cased because the role is right and useless: a
    /// Tempest station is a `.timeseries` like a battery monitor is, and on a
    /// map full of pins the thing a user looks for is the weather icon.
    ///
    /// But only when the role table has nothing distinctive to say. A camera
    /// mounted at a weather station is a camera on the map — the more specific
    /// role beats the keyword every time.
    static func symbol(for system: RemoteSystem) -> String {
        if isWeather(system), Self.weakRoles.contains(system.primaryRole.label) {
            return "cloud.sun.fill"
        }
        return symbol(for: system.primaryRole)
    }

    /// Roles that say what a stream's *values* look like rather than what the
    /// system *is*, and so lose to the weather keyword.
    private static let weakRoles: Set<String> = ["timeseries", "status", "generic"]

    /// True when any datastream describes weather.
    ///
    /// Names as well as definitions, because the reference node's Tempest
    /// driver defines its record as "TempestOutputObservation" and says
    /// "weather" nowhere — the temperature field is what gives it away.
    static func isWeather(_ system: RemoteSystem) -> Bool {
        for datastream in system.datastreams {
            let haystacks = [datastream.summary.name,
                             datastream.summary.outputName,
                             datastream.recordSchema?.name,
                             datastream.recordSchema?.definition,
                             datastream.recordSchema?.label].compactMap { $0 }
            if haystacks.contains(where: { text in
                keywords.contains { text.localizedCaseInsensitiveContains($0) }
            }) { return true }

            guard let record = datastream.recordSchema else { continue }
            for leaf in SchemaWalker.leaves(of: record) {
                let fields = [leaf.path.lastComponent, leaf.component.definition].compactMap { $0 }
                if fields.contains(where: { text in
                    keywords.contains { text.localizedCaseInsensitiveContains($0) }
                }) { return true }
            }
        }
        return false
    }

    private static let keywords = ["weather", "temp", "atmospheric"]
}
