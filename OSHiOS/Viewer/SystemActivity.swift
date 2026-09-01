import Foundation

// MARK: - System activity
//
// How recently a system said anything.
//
// Every surface in the app asks this question and none of them should answer it
// differently: a marker that reads green on the map and a row that reads amber
// in the list are describing the same system, and one of them is lying. So the
// thresholds live here, once, and everything else consumes the result.
//
// The answer comes from two places and they layer. At rest, a datastream's
// reported phenomenonTimeRange is enough — listDatastreams already returns it,
// so a whole node can be classified without opening a single stream. Once
// something is streaming, ActivityTracker takes over with the arrival times of
// real observations.

// MARK: - ActivityThresholds

/// The two ages that split live from stale from offline.
///
/// One place because they will become a setting: a 5-minute "live" is right for
/// a camera and absurd for a tide gauge that reports twice a day, and when that
/// becomes configurable this is the only thing that has to change.
enum ActivityThresholds {
    /// Newer than this is `.live`.
    static let live: TimeInterval = 300
    /// Newer than this — but older than `live` — is `.stale`.
    static let stale: TimeInterval = 1800
}

// MARK: - ActivityState

enum ActivityState: Equatable, Sendable {
    /// Newest observation ≤ 5 min old.
    case live
    /// ≤ 30 min.
    case stale
    /// > 30 min, or no observations at all.
    case offline

    /// Classifies one timestamp.
    ///
    /// nil is `.offline` rather than a fourth "unknown" case on purpose: a
    /// system that has never produced an observation and one that stopped
    /// producing them last year are the same thing to someone looking at a map.
    static func of(_ lastObservation: Date?, now: Date) -> ActivityState {
        guard let lastObservation else { return .offline }
        // A timestamp in the future is a clock skew, not a stale reading, so it
        // counts as live rather than wrapping round to offline.
        let age = now.timeIntervalSince(lastObservation)
        if age <= ActivityThresholds.live { return .live }
        if age <= ActivityThresholds.stale { return .stale }
        return .offline
    }

    /// Sort rank for "live first, then stale, then offline".
    var sortRank: Int {
        switch self {
        case .live:    return 0
        case .stale:   return 1
        case .offline: return 2
        }
    }

    var label: String {
        switch self {
        case .live:    return "live"
        case .stale:   return "stale"
        case .offline: return "offline"
        }
    }
}

// MARK: - SystemActivity

struct SystemActivity: Equatable, Sendable {

    let state: ActivityState
    let lastObservation: Date?
    /// Per-datastream last-seen, for detail views.
    let perDatastream: [String: Date]

    init(state: ActivityState,
         lastObservation: Date?,
         perDatastream: [String: Date] = [:]) {
        self.state = state
        self.lastObservation = lastObservation
        self.perDatastream = perDatastream
    }

    /// Nothing known — a system whose datastreams have not been read yet.
    static let unknown = SystemActivity(state: .offline, lastObservation: nil)

    /// A system that is producing data right now, by construction. This device
    /// while its session streams is the only caller.
    static func liveNow(_ now: Date) -> SystemActivity {
        SystemActivity(state: .live, lastObservation: now)
    }

    // MARK: Derivation

    /// Activity from what `listDatastreams` already said, with no stream opened.
    ///
    /// `phenomenonTimeRange` is preferred and `resultTimeRange` is the fallback:
    /// they are usually the same instant, and where they differ the phenomenon
    /// time is when the world did something rather than when the node wrote it
    /// down.
    ///
    /// An open-ended upper bound — the node writes "now", and OGC's own
    /// vocabulary allows "latest" — means data is flowing, so it resolves to
    /// `now()` rather than being discarded. That single rule is what makes a
    /// replay-backed node read as live instead of as an archive.
    static func derive(from summaries: [DatastreamSummary],
                       now: () -> Date = Date.init) -> SystemActivity {

        let evaluatedAt = now()
        var perDatastream: [String: Date] = [:]

        for summary in summaries {
            guard let end = endOfRange(summary, openEndedAs: evaluatedAt) else { continue }
            perDatastream[summary.id] = end
        }

        let newest = perDatastream.values.max()
        return SystemActivity(state: .of(newest, now: evaluatedAt),
                              lastObservation: newest,
                              perDatastream: perDatastream)
    }

    /// The instant one datastream last produced something, as best it says.
    static func endOfRange(_ summary: DatastreamSummary,
                           openEndedAs openEnded: Date) -> Date? {
        for range in [summary.phenomenonTimeRange, summary.resultTimeRange] {
            guard let bound = range?.last else { continue }
            if isOpenEnded(bound) { return openEnded }
            if let date = ISO8601DateFormatter.parse(bound) { return date }
        }
        return nil
    }

    /// The markers a node uses for "and it is still going".
    static func isOpenEnded(_ bound: String) -> Bool {
        openEndedMarkers.contains { bound.caseInsensitiveCompare($0) == .orderedSame }
    }

    private static let openEndedMarkers = ["now", "latest"]
}
