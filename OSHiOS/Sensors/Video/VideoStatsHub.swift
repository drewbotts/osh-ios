import Foundation

// MARK: - VideoStatsHub
//
// Accumulates encoder throughput and fans a snapshot out to any number of
// AsyncStream consumers once per reporting window.
//
// Lock-based rather than an actor for the same reason FrameGate is: frames are
// recorded synchronously from the capture queue, which must not suspend. The
// lock is held only across a handful of integer updates.

final class VideoStatsHub: @unchecked Sendable {

    private let lock = NSLock()

    // Accumulated over the current window, reset on each tick.
    private var windowFrames = 0
    private var windowBytes  = 0

    private var width  = 0
    private var height = 0

    private var latest = VideoStats()
    private var continuations: [UUID: AsyncStream<VideoStats>.Continuation] = [:]

    // MARK: Recording (capture queue)

    /// One encoded frame of `bytes` bytes was produced.
    func record(frameBytes bytes: Int) {
        lock.lock()
        windowFrames += 1
        windowBytes  += bytes
        lock.unlock()
    }

    /// The dimensions the encoder is actually producing.
    func reportDimensions(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        lock.lock()
        self.width  = width
        self.height = height
        latest.width  = width
        latest.height = height
        let snapshot = latest
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets { continuation.yield(snapshot) }
    }

    // MARK: Reporting

    /// Closes the current window and publishes a snapshot.
    /// - Parameters:
    ///   - interval: seconds the window covered.
    ///   - dropped: cumulative dropped-frame count from the frame gate.
    func tick(interval: Double, dropped: Int) {
        lock.lock()
        let frames = windowFrames
        let bytes  = windowBytes
        windowFrames = 0
        windowBytes  = 0

        latest = VideoStats(
            encodedFPS: interval > 0 ? Double(frames) / interval : 0,
            bitrateKbps: interval > 0 ? Double(bytes) * 8.0 / 1000.0 / interval : 0,
            droppedFrames: dropped,
            width: width,
            height: height)
        let snapshot = latest
        let targets = Array(continuations.values)
        lock.unlock()

        for continuation in targets { continuation.yield(snapshot) }
    }

    // MARK: Streams

    /// A new stream that immediately yields the current snapshot, then one
    /// value per reporting window. Finishes when `finish()` is called.
    func makeStream() -> AsyncStream<VideoStats> {
        // bufferingNewest(1): a stats snapshot supersedes its predecessor, so a
        // slow consumer should see the latest window, not a backlog of old ones.
        let (stream, continuation) = AsyncStream<VideoStats>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let id = UUID()

        lock.lock()
        continuations[id] = continuation
        let snapshot = latest
        lock.unlock()

        continuation.onTermination = { [weak self] _ in
            self?.removeContinuation(id)
        }
        continuation.yield(snapshot)
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        windowFrames = 0
        windowBytes  = 0
        lock.unlock()
        for continuation in targets { continuation.finish() }
    }
}
