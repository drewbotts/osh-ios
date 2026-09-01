import Foundation
import Combine

// MARK: - ActivityTracker
//
// One place that knows how fresh every system is, shared by every surface.
//
// The map, the video wall and the systems list all draw a status dot, and they
// have to agree — so none of them derives its own. A view reads the tracker;
// the tracker is fed from two sides. RemoteSystem.activity seeds it from what
// the node said at load, and every observation that arrives through any
// SystemLiveSession promotes its system in real time.
//
// Two decisions keep it cheap on a phone.
//
// Arrival times are recorded in a plain dictionary and are *not* published. A
// 10 Hz AIS stream would otherwise publish a hundred dictionary mutations a
// second and redraw every marker on the map for a colour that did not change.
// `states` is published, and it is only reassigned when a state genuinely
// crosses a threshold.
//
// And decay needs a clock of its own. Nothing arrives when a system goes quiet,
// which is exactly the moment its dot has to stop being green — so a 30 s timer
// re-evaluates every entry against the thresholds and publishes only the ones
// that moved.

@MainActor
final class ActivityTracker: ObservableObject {

    // MARK: Shared instance

    /// The app's tracker.
    ///
    /// A singleton because sessions are created in four places — the COP map,
    /// the video wall, a dashboard and the systems list — and every one of them
    /// has to feed the same freshness picture. Threading an instance through
    /// each construction site would make "which tracker did this session
    /// report to" a question the app could get wrong. Tests build their own
    /// with an injected clock.
    static let shared = ActivityTracker()

    // MARK: Key

    /// Two nodes can mint the same system id, so the server is part of the
    /// identity. Nothing here is ever keyed by system id alone.
    struct Key: Hashable, Sendable {
        let serverId: UUID
        let systemId: String

        init(serverId: UUID, systemId: String) {
            self.serverId = serverId
            self.systemId = systemId
        }
    }

    // MARK: Published state

    /// Current state per system. Reassigned only when something changes state.
    @Published private(set) var states: [Key: ActivityState] = [:]

    /// This device, which is live by definition while its session streams.
    @Published var isLocalDeviceStreaming = false

    /// Bumped by the decay timer so relative "last seen" text re-renders
    /// without new data. Views need not read it; observing the object is enough.
    @Published private(set) var evaluations = 0

    // MARK: Configuration

    /// How often states are re-evaluated against the thresholds.
    static let reevaluationInterval: TimeInterval = 30

    // MARK: Private state

    /// Last-seen per datastream, per system. Deliberately unpublished.
    private var lastSeen: [Key: [String: Date]] = [:]
    private var decayTask: Task<Void, Never>?

    /// Injected for tests; `Date.init` everywhere else.
    private let now: () -> Date

    // MARK: Init

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    // MARK: Lifecycle

    /// Starts the decay re-evaluation. Idempotent.
    func start() {
        guard decayTask == nil else { return }
        decayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.reevaluationInterval))
                guard let self, !Task.isCancelled else { return }
                self.reevaluate()
            }
        }
    }

    func stop() {
        decayTask?.cancel()
        decayTask = nil
    }

    // MARK: Feeding

    /// Seeds a system from what its datastream summaries reported at load.
    ///
    /// Never overwrites a fresher fact: a stream that has been running since
    /// the tracker started knows more than a summary fetched a minute ago.
    func seed(_ activity: SystemActivity, serverId: UUID, systemId: String) {
        let key = Key(serverId: serverId, systemId: systemId)
        var seen = lastSeen[key] ?? [:]
        for (datastreamId, date) in activity.perDatastream {
            if let existing = seen[datastreamId], existing >= date { continue }
            seen[datastreamId] = date
        }
        lastSeen[key] = seen
        publishState(for: key)
    }

    /// Records one observation's timestamp.
    ///
    /// Phenomenon time rather than arrival time, so this measures the same
    /// thing `derive(from:)` does — "the newest observation is N seconds old".
    /// It matters because a session bootstraps from the archive before the
    /// socket opens: a page of last June's records must not turn a dead system
    /// green just because the fetch completed a moment ago.
    ///
    /// Called for every observation on every open stream, so it does no work
    /// beyond a dictionary write and a threshold compare.
    func record(datastreamId: String,
                at phenomenonTime: Date,
                serverId: UUID,
                systemId: String) {
        let key = Key(serverId: serverId, systemId: systemId)
        if let existing = lastSeen[key]?[datastreamId], existing >= phenomenonTime { return }
        lastSeen[key, default: [:]][datastreamId] = phenomenonTime
        publishState(for: key)
    }

    /// Convenience for a whole batch off one stream.
    func record(_ observation: ParsedObservation, serverId: UUID, systemId: String) {
        record(datastreamId: observation.datastreamId,
               at: observation.phenomenonTime,
               serverId: serverId,
               systemId: systemId)
    }

    // MARK: Reading

    func state(serverId: UUID, systemId: String) -> ActivityState {
        states[Key(serverId: serverId, systemId: systemId)] ?? .offline
    }

    /// Everything known about one system, including the per-datastream detail.
    func activity(serverId: UUID, systemId: String) -> SystemActivity {
        let key = Key(serverId: serverId, systemId: systemId)
        let seen = lastSeen[key] ?? [:]
        let newest = seen.values.max()
        return SystemActivity(state: ActivityState.of(newest, now: now()),
                              lastObservation: newest,
                              perDatastream: seen)
    }

    /// This device's activity — live while streaming, offline otherwise.
    var localDeviceActivity: SystemActivity {
        isLocalDeviceStreaming ? .liveNow(now()) : SystemActivity(state: .offline,
                                                                  lastObservation: nil)
    }

    // MARK: Evaluation

    /// Re-derives every state and publishes only the ones that moved.
    func reevaluate() {
        let evaluatedAt = now()
        var changed: [Key: ActivityState] = [:]

        for (key, seen) in lastSeen {
            let state = ActivityState.of(seen.values.max(), now: evaluatedAt)
            if states[key] != state { changed[key] = state }
        }

        if !changed.isEmpty {
            for (key, state) in changed { states[key] = state }
        }
        // Bumped unconditionally: "last seen 12 min ago" ages even when the
        // state has not crossed a threshold, and that text has no other clock.
        evaluations &+= 1
    }

    private func publishState(for key: Key) {
        let state = ActivityState.of(lastSeen[key]?.values.max(), now: now())
        guard states[key] != state else { return }
        states[key] = state
    }
}
