import Foundation

// MARK: - LogLevel

/// Severity, ordered so a filter can say "warning and above".
enum LogLevel: Int, Comparable, Sendable, CaseIterable {
    case debug, info, notice, warning, error, fault

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .notice:  return "NOTICE"
        case .warning: return "WARN"
        case .error:   return "ERROR"
        case .fault:   return "FAULT"
        }
    }
}

// MARK: - LogEntry

struct LogEntry: Identifiable, Sendable, Equatable {
    /// Monotonic ingest order. Entries reach the store through unstructured
    /// tasks, which are not ordered among themselves, so this — not the
    /// timestamp — is what puts the log back in the order it was written.
    let sequence: UInt64
    let date: Date
    let level: LogLevel
    let subsystem: String
    let category: String
    let message: String

    var id: UInt64 { sequence }
}

// MARK: - LogStore
//
// The in-app tail of the unified log. os.Logger writes are invisible to the app
// that made them — OSLogStore can technically read them back but is unreliable
// in-process and needs entitlements a normal install does not carry — so
// OSHLogger writes to both: os.Logger for Console.app and `log stream`, and
// this store for the Logs tab.
//
// Capacity is fixed at 2,000 entries; the oldest are dropped. Live consumers
// get an AsyncStream of new entries, and `snapshot()` returns everything held.

actor LogStore {

    static let shared = LogStore()

    /// Maximum entries retained.
    static let capacity = 2_000

    private var entries: [LogEntry] = []
    private var continuations: [UUID: AsyncStream<LogEntry>.Continuation] = [:]

    // MARK: Ingest

    /// Stamps and files one entry. Callable from anywhere, including hardware
    /// callback queues, and never suspends the caller.
    nonisolated func record(level: LogLevel,
                            subsystem: String,
                            category: String,
                            message: String) {
        let entry = LogEntry(sequence: Self.nextSequence(),
                             date: Date(),
                             level: level,
                             subsystem: subsystem,
                             category: category,
                             message: message)
        Task { await self.append(entry) }
    }

    /// Files an entry directly. Ordinary code goes through `record`; this is
    /// the seam the tests use to fill the ring deterministically.
    func append(_ entry: LogEntry) {
        // Near-sorted in practice: walk back only far enough to place an entry
        // whose task happened to be scheduled out of order.
        var index = entries.count
        while index > 0, entries[index - 1].sequence > entry.sequence {
            index -= 1
        }
        entries.insert(entry, at: index)

        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        for continuation in continuations.values { continuation.yield(entry) }
    }

    // MARK: Reading

    func snapshot() -> [LogEntry] { entries }

    /// A new stream of entries recorded from now on.
    func updates() -> AsyncStream<LogEntry> {
        // bufferingNewest: a burst of log lines must not stall the logger;
        // dropping the oldest pending line beats unbounded growth.
        let (stream, continuation) = AsyncStream<LogEntry>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.capacity))
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    func clear() {
        entries.removeAll()
    }

    // MARK: Sequence

    private static let sequenceLock = NSLock()
    nonisolated(unsafe) private static var sequenceCounter: UInt64 = 0

    /// The one piece of state that must be assigned before the ingest task is
    /// even created, so it is guarded by a lock rather than by the actor.
    nonisolated static func nextSequence() -> UInt64 {
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        sequenceCounter += 1
        return sequenceCounter
    }
}
