import Foundation

// MARK: - SensorLiveState
//
// Everything the UI knows about one output while a session runs. Nothing here
// names a sensor class: the schema is the description, and ParsedObservation
// carries the values. That is what lets one card component render a local GPS
// output today and a remote datastream fetched from a node later.

struct SensorLiveState: Identifiable {

    /// Whether the output is producing data right now.
    enum Availability: Equatable {
        /// An observation arrived recently.
        case active
        /// Started, but nothing has arrived for longer than `staleAfter`.
        case stale
        /// The hardware refused to start, with the reason to show the user.
        case unavailable(String)
    }

    /// Observations older than this mark the output stale.
    static let staleAfter: TimeInterval = 3.0

    /// How many observations are kept for sparklines.
    static let historyLimit = 60

    /// Window used for the observations-per-second figure.
    static let rateWindow: TimeInterval = 5.0

    let id: String                  // outputName
    let displayName: String
    let schema: DataRecord

    var latest: ParsedObservation?
    /// Ring of the last `historyLimit` observations, oldest first.
    var history: [ParsedObservation] = []
    var lastUpdate: Date?
    var availability: Availability = .stale
    var stats = StreamStats()

    /// Arrival times inside the rate window, used to compute `stats.rate`.
    private var recentArrivals: [Date] = []

    init(id: String, displayName: String, schema: DataRecord) {
        self.id = id
        self.displayName = displayName
        self.schema = schema
    }

    // MARK: Mutation

    /// Records a newly parsed observation and refreshes the derived figures.
    mutating func append(_ observation: ParsedObservation, at now: Date = Date()) {
        latest = observation
        history.append(observation)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        lastUpdate = now
        availability = .active

        recentArrivals.append(now)
        recomputeRate(now: now)
    }

    /// Re-evaluates staleness against the clock. Called from the session's
    /// 1 s tick so a sensor that quietly stops is visible as such.
    mutating func refreshAvailability(now: Date = Date()) {
        if case .unavailable = availability { return }
        guard let lastUpdate else {
            availability = .stale
            return
        }
        availability = now.timeIntervalSince(lastUpdate) > Self.staleAfter ? .stale : .active
        recomputeRate(now: now)
    }

    /// An output that could not start at all. Terminal for the session.
    mutating func markUnavailable(_ reason: String) {
        availability = .unavailable(reason)
        recentArrivals.removeAll()
        stats.rate = 0
    }

    private mutating func recomputeRate(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.rateWindow)
        recentArrivals.removeAll { $0 < cutoff }
        stats.rate = Double(recentArrivals.count) / Self.rateWindow
    }
}

// MARK: - StreamStats

/// Delivery counters for one datastream, as shown next to a sensor and next to
/// its row on the Node tab.
struct StreamStats: Equatable {
    /// Observations accepted by the node.
    var observations: Int = 0
    /// Request-body bytes sent.
    var bytes: Int = 0
    /// Failed POSTs.
    var errors: Int = 0
    /// Observations per second produced locally, over a 5 s window.
    var rate: Double = 0
}
