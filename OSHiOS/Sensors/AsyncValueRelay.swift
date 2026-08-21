import Foundation

// MARK: - AsyncValueRelay
//
// Multicasts the latest value of a side channel to any number of AsyncStream
// consumers. Used where a sensor has something to report that is not an
// observation — GPS horizontal accuracy, for instance, which the SWE schema
// deliberately does not carry but the map needs to draw an accuracy circle.
//
// Lock-based rather than an actor because senders are hardware callbacks on
// their own queues that must not suspend. Each new stream replays the most
// recent value, so a consumer that subscribes late is not left blank until the
// next update arrives.

final class AsyncValueRelay<Value: Sendable>: @unchecked Sendable {

    private let lock = NSLock()
    private var latest: Value?
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    func send(_ value: Value) {
        lock.lock()
        latest = value
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets { continuation.yield(value) }
    }

    /// A new stream, replaying the current value if there is one.
    func stream() -> AsyncStream<Value> {
        // bufferingNewest(1): these are state snapshots, not events — a slow
        // consumer wants the current value, not a queue of superseded ones.
        let (stream, continuation) = AsyncStream<Value>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let id = UUID()

        lock.lock()
        continuations[id] = continuation
        let replay = latest
        lock.unlock()

        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        if let replay { continuation.yield(replay) }
        return stream
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets { continuation.finish() }
    }
}
