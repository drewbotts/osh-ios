import Testing
import Foundation
@testable import osh_ios

// MARK: - SystemActivityTests
//
// Freshness, which is the one thing in the viewer that changes without any new
// data arriving. Two halves: deriving a state from what a node reported, and
// keeping it honest as time passes.
//
// Every test injects its clock. A test that called Date() would be testing the
// machine it runs on — and the decay case, where the whole point is that
// nothing arrives, cannot be written at all without one.

@Suite("System activity")
struct SystemActivityTests {

    // MARK: Fixtures

    /// A fixed instant, so "five minutes ago" means the same thing every run.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter.flexible.string(from: date)
    }

    /// A datastream summary whose phenomenonTime ends `secondsAgo` before `now`.
    private static func summary(id: String, secondsAgo: TimeInterval) -> DatastreamSummary {
        let end = now.addingTimeInterval(-secondsAgo)
        return DatastreamSummary(id: id,
                                 name: id,
                                 phenomenonTimeRange: [iso(end.addingTimeInterval(-60)), iso(end)])
    }

    // MARK: Thresholds

    @Test("A newest observation inside five minutes is live")
    func liveThreshold() {
        let activity = SystemActivity.derive(from: [Self.summary(id: "a", secondsAgo: 60)],
                                             now: { Self.now })
        #expect(activity.state == .live)
        #expect(activity.lastObservation == Self.now.addingTimeInterval(-60))
    }

    @Test("Between five and thirty minutes is stale")
    func staleThreshold() {
        let activity = SystemActivity.derive(from: [Self.summary(id: "a", secondsAgo: 15 * 60)],
                                             now: { Self.now })
        #expect(activity.state == .stale)
    }

    @Test("Past thirty minutes is offline")
    func offlineThreshold() {
        let activity = SystemActivity.derive(from: [Self.summary(id: "a", secondsAgo: 2 * 3600)],
                                             now: { Self.now })
        #expect(activity.state == .offline)
    }

    @Test("No datastreams at all is offline with nothing to show")
    func nothingObserved() {
        let activity = SystemActivity.derive(from: [], now: { Self.now })
        #expect(activity.state == .offline)
        #expect(activity.lastObservation == nil)
        #expect(activity.perDatastream.isEmpty)
    }

    /// The rule that makes a replay-backed node read as live rather than as an
    /// archive: an open-ended range means data is still flowing.
    @Test("An open-ended range end is live as of now", arguments: ["now", "NOW", "latest"])
    func openEndedIsLive(marker: String) {
        let summary = DatastreamSummary(id: "a",
                                        name: "a",
                                        phenomenonTimeRange: ["2020-01-01T00:00:00Z", marker])
        let activity = SystemActivity.derive(from: [summary], now: { Self.now })
        #expect(activity.state == .live)
        #expect(activity.lastObservation == Self.now)
    }

    @Test("resultTime is the fallback when phenomenonTime is absent")
    func resultTimeFallback() {
        let end = Self.now.addingTimeInterval(-120)
        let summary = DatastreamSummary(id: "a",
                                        name: "a",
                                        resultTimeRange: [Self.iso(end), Self.iso(end)])
        let activity = SystemActivity.derive(from: [summary], now: { Self.now })
        #expect(activity.state == .live)
        #expect(activity.lastObservation == end)
    }

    /// The mixed case a real system is in: the freshest stream is what the
    /// system's own state means, and every stream keeps its own last-seen for
    /// the detail views.
    @Test("The freshest datastream sets the system's state")
    func mixedDatastreams() {
        let activity = SystemActivity.derive(from: [
            Self.summary(id: "offline", secondsAgo: 4 * 3600),
            Self.summary(id: "stale", secondsAgo: 20 * 60),
            Self.summary(id: "live", secondsAgo: 30)
        ], now: { Self.now })

        #expect(activity.state == .live)
        #expect(activity.perDatastream.count == 3)
        #expect(activity.lastObservation == Self.now.addingTimeInterval(-30))
    }

    @Test("An unparseable range end is skipped rather than counted")
    func malformedRange() {
        let summary = DatastreamSummary(id: "a", name: "a",
                                        phenomenonTimeRange: ["not a date", "also not"])
        let activity = SystemActivity.derive(from: [summary], now: { Self.now })
        #expect(activity.state == .offline)
        #expect(activity.perDatastream.isEmpty)
    }

    // MARK: Tracker

    /// A clock the test moves by hand.
    @MainActor
    private final class Clock {
        var now: Date
        init(_ start: Date) { now = start }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    @MainActor
    @Test("An arriving observation promotes a system to live")
    func promotionOnArrival() {
        let clock = Clock(Self.now)
        let tracker = ActivityTracker(now: { clock.now })
        let serverId = UUID()

        tracker.seed(SystemActivity.derive(from: [Self.summary(id: "a", secondsAgo: 3 * 3600)],
                                           now: { clock.now }),
                     serverId: serverId, systemId: "sys")
        #expect(tracker.state(serverId: serverId, systemId: "sys") == .offline)

        tracker.record(datastreamId: "a", at: clock.now,
                       serverId: serverId, systemId: "sys")
        #expect(tracker.state(serverId: serverId, systemId: "sys") == .live)
    }

    /// The case a timer exists for: nothing arrives, and the state has to move
    /// anyway.
    @MainActor
    @Test("A system decays through stale to offline when nothing arrives")
    func decayOnReevaluation() {
        let clock = Clock(Self.now)
        let tracker = ActivityTracker(now: { clock.now })
        let serverId = UUID()

        tracker.record(datastreamId: "a", at: clock.now, serverId: serverId, systemId: "sys")
        #expect(tracker.state(serverId: serverId, systemId: "sys") == .live)

        clock.advance(ActivityThresholds.live + 1)
        tracker.reevaluate()
        #expect(tracker.state(serverId: serverId, systemId: "sys") == .stale)

        clock.advance(ActivityThresholds.stale)
        tracker.reevaluate()
        #expect(tracker.state(serverId: serverId, systemId: "sys") == .offline)
    }

    @MainActor
    @Test("Seeding never overwrites a fresher arrival")
    func seedDoesNotRegress() {
        let clock = Clock(Self.now)
        let tracker = ActivityTracker(now: { clock.now })
        let serverId = UUID()

        tracker.record(datastreamId: "a", at: clock.now, serverId: serverId, systemId: "sys")
        // A listing fetched a moment ago, reporting an hour-old tail.
        tracker.seed(SystemActivity.derive(from: [Self.summary(id: "a", secondsAgo: 3600)],
                                           now: { clock.now }),
                     serverId: serverId, systemId: "sys")

        #expect(tracker.state(serverId: serverId, systemId: "sys") == .live)
    }

    /// Two nodes can mint the same system id, which is why nothing is ever
    /// keyed by system id alone.
    @MainActor
    @Test("Two servers with the same system id do not share a state")
    func serversAreIndependent() {
        let clock = Clock(Self.now)
        let tracker = ActivityTracker(now: { clock.now })
        let first = UUID(), second = UUID()

        tracker.record(datastreamId: "a", at: clock.now, serverId: first, systemId: "sys")

        #expect(tracker.state(serverId: first, systemId: "sys") == .live)
        #expect(tracker.state(serverId: second, systemId: "sys") == .offline)
    }

    @MainActor
    @Test("This device is live exactly while its session streams")
    func localDeviceActivity() {
        let clock = Clock(Self.now)
        let tracker = ActivityTracker(now: { clock.now })

        #expect(tracker.localDeviceActivity.state == .offline)
        tracker.isLocalDeviceStreaming = true
        #expect(tracker.localDeviceActivity.state == .live)
        #expect(tracker.localDeviceActivity.lastObservation == clock.now)
    }

    // MARK: Sorting

    @Test("Live sorts before stale sorts before offline")
    func sortOrder() {
        let ranks = [ActivityState.offline, .live, .stale]
            .sorted { $0.sortRank < $1.sortRank }
        #expect(ranks == [.live, .stale, .offline])
    }
}
