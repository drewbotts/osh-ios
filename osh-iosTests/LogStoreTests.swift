import Foundation
import Testing
@testable import osh_ios

// MARK: - LogStore
//
// The store is the Logs tab's only source of history, so its ring behaviour is
// what decides whether the beginning of a long session is still readable.
//
// These tests file entries through `append` rather than `record` because
// `record` hands off to an unstructured task: the ring semantics are the
// subject here, not the scheduler.

struct LogStoreTests {

    private func entry(_ sequence: UInt64,
                       level: LogLevel = .info,
                       category: String = "session") -> LogEntry {
        LogEntry(sequence: sequence,
                 date: Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence)),
                 level: level,
                 subsystem: Log.subsystem,
                 category: category,
                 message: "entry \(sequence)")
    }

    @Test func appendedEntriesComeBackInOrder() async {
        let store = LogStore()
        for index in 1...5 { await store.append(entry(UInt64(index))) }

        let snapshot = await store.snapshot()
        #expect(snapshot.map(\.sequence) == [1, 2, 3, 4, 5])
    }

    /// Tasks are not ordered among themselves, so an entry can arrive after one
    /// that was written later. The sequence number is what repairs that.
    @Test func outOfOrderArrivalsAreSortedBySequence() async {
        let store = LogStore()
        for sequence in [UInt64(3), 1, 5, 2, 4] {
            await store.append(entry(sequence))
        }

        let snapshot = await store.snapshot()
        #expect(snapshot.map(\.sequence) == [1, 2, 3, 4, 5])
    }

    @Test func ringDropsOldestPastCapacity() async {
        let store = LogStore()
        let overflow = 25
        for index in 1...(LogStore.capacity + overflow) {
            await store.append(entry(UInt64(index)))
        }

        let snapshot = await store.snapshot()
        #expect(snapshot.count == LogStore.capacity)
        // The oldest `overflow` entries are gone; the newest are all present.
        #expect(snapshot.first?.sequence == UInt64(overflow + 1))
        #expect(snapshot.last?.sequence == UInt64(LogStore.capacity + overflow))
    }

    @Test func clearEmptiesTheRing() async {
        let store = LogStore()
        for index in 1...10 { await store.append(entry(UInt64(index))) }
        await store.clear()

        let snapshot = await store.snapshot()
        #expect(snapshot.isEmpty)
    }

    @Test func updatesStreamCarriesNewEntries() async {
        let store = LogStore()
        let stream = await store.updates()

        await store.append(entry(1))
        await store.append(entry(2))

        var received: [UInt64] = []
        for await entry in stream {
            received.append(entry.sequence)
            if received.count == 2 { break }
        }
        #expect(received == [1, 2])
    }

    /// Sequence numbers are handed out before the ingest task is created, so
    /// they must be unique even under concurrent logging.
    @Test func sequenceNumbersAreUnique() async {
        let count = 500
        let sequences = await withTaskGroup(of: UInt64.self) { group -> Set<UInt64> in
            for _ in 0..<count {
                group.addTask { LogStore.nextSequence() }
            }
            var seen: Set<UInt64> = []
            for await value in group { seen.insert(value) }
            return seen
        }
        #expect(sequences.count == count)
    }
}

// MARK: - Level filter ordering

struct LogLevelTests {

    @Test func levelsAreOrderedBySeverity() {
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.info < LogLevel.warning)
        #expect(LogLevel.warning < LogLevel.error)
        #expect(LogLevel.error < LogLevel.fault)
    }

    /// "Warn+" has to include faults, or the most serious line in the log is
    /// the one the filter hides.
    @Test func warningFilterIncludesEverythingAbove() {
        let minimum = LogsViewModel.LevelFilter.warning.minimum
        #expect(LogLevel.warning >= minimum)
        #expect(LogLevel.error >= minimum)
        #expect(LogLevel.fault >= minimum)
        #expect(!(LogLevel.info >= minimum))
    }
}

// MARK: - Message rendering

struct LogMessageTests {

    @Test func interpolationRendersValues() {
        let message: LogMessage = "count \(42) name \("gps_data", privacy: .public)"
        #expect(message.description == "count 42 name gps_data")
    }

    /// A value marked private is redacted before it reaches either sink, so the
    /// Logs tab shows exactly what Console.app would.
    @Test func privateValuesAreRedacted() {
        let message: LogMessage = "token \("s3cret", privacy: .private)"
        #expect(message.description == "token <private>")
    }

    @Test func plainLiteralsPassThrough() {
        let message: LogMessage = "Registering system…"
        #expect(message.description == "Registering system…")
    }
}
