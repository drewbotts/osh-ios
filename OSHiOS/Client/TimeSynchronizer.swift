import Foundation

// MARK: - TimeSynchronizer
//
// Buffers observations from several datastreams and releases them in
// phenomenonTime order. A port of OSHConnect-Java's TimeSynchronizer.
//
// The problem it solves is that arrival order is not observation order. Two
// datastreams on the same node take different paths through it — one is
// archived and replayed, another is live; one carries 300 KB frames and another
// 32-byte records — so a video frame and the GPS fix taken at the same instant
// can arrive hundreds of milliseconds apart. Playing them back in arrival order
// puts the pin somewhere the camera was not looking.
//
// The trade is latency for order: nothing is released until it has been held
// for `bufferMillis`, by which time anything that belonged before it has
// almost certainly arrived.

actor TimeSynchronizer {

    // MARK: Configuration

    /// How long an observation is held before it may be released.
    let bufferMillis: Int

    /// Whether an observation that arrives already older than the release
    /// frontier is dropped rather than emitted out of order.
    ///
    /// Dropping is usually right for a live view, where a late record would
    /// make the display jump backwards. Keeping is right for an export, where
    /// completeness matters more than monotonicity.
    let discardOutdated: Bool

    /// How often the buffer is examined.
    private static let tickMillis = 10

    // MARK: State

    private var buffer: [ParsedObservation] = []
    private var latestReleased: Date?
    private var tick: Task<Void, Never>?

    private let continuation: AsyncStream<ParsedObservation>.Continuation

    /// Observations in phenomenonTime order.
    nonisolated let observations: AsyncStream<ParsedObservation>

    // MARK: Init

    init(bufferMillis: Int = 1000, discardOutdated: Bool = true) {
        self.bufferMillis = bufferMillis
        self.discardOutdated = discardOutdated
        (self.observations, self.continuation) = AsyncStream<ParsedObservation>.makeStream(
            bufferingPolicy: .bufferingNewest(1024))
    }

    // MARK: Lifecycle

    func start() {
        guard tick == nil else { return }
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Self.tickMillis))
                await self?.release()
            }
        }
    }

    func stop() {
        tick?.cancel()
        tick = nil
        continuation.finish()
    }

    // MARK: Input

    func add(_ observation: ParsedObservation) {
        if discardOutdated, let frontier = latestReleased,
           observation.phenomenonTime < frontier.addingTimeInterval(-Double(bufferMillis) / 1000) {
            return
        }

        // Insertion sort into an almost-sorted buffer: observations arrive
        // nearly in order, so the scan is short, and it keeps the release step
        // to a look at the head rather than a sort per tick.
        let index = buffer.lastIndex { $0.phenomenonTime <= observation.phenomenonTime }
        buffer.insert(observation, at: index.map { $0 + 1 } ?? 0)
    }

    func add(_ observations: [ParsedObservation]) {
        for observation in observations { add(observation) }
    }

    // MARK: Output

    /// Emits everything held longer than the buffer window.
    ///
    /// The cutoff is measured against the newest observation in hand rather
    /// than against wall-clock now(), so a replay running at 10× or a fixture
    /// fed in as fast as it can be read releases at the same rate it would
    /// live — the buffer is a reordering window, not a rate limiter.
    private func release() {
        guard let newest = buffer.last?.phenomenonTime else { return }
        let cutoff = newest.addingTimeInterval(-Double(bufferMillis) / 1000)

        while let first = buffer.first, first.phenomenonTime <= cutoff {
            buffer.removeFirst()
            latestReleased = first.phenomenonTime
            continuation.yield(first)
        }
    }

    /// Releases everything still held, in order. For end-of-stream.
    func flush() {
        for observation in buffer {
            latestReleased = observation.phenomenonTime
            continuation.yield(observation)
        }
        buffer.removeAll()
    }

    /// How many observations are currently held.
    var bufferedCount: Int { buffer.count }
}
