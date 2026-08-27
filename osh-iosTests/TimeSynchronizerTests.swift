import Testing
import Foundation
@testable import osh_ios

// MARK: - TimeSynchronizerTests

@Suite("Time synchronizer")
struct TimeSynchronizerTests {

    private func observation(_ id: String, _ offset: TimeInterval) -> ParsedObservation {
        ParsedObservation(datastreamId: id,
                          phenomenonTime: Date(timeIntervalSince1970: 1_787_795_000 + offset),
                          values: [:],
                          orderedPaths: [])
    }

    @Test("Observations arriving out of order are released in time order")
    func reordersAcrossDatastreams() async throws {
        let synchronizer = TimeSynchronizer(bufferMillis: 100)

        // Interleaved as two datastreams would deliver them: each is internally
        // ordered, but the merge of the two is not.
        await synchronizer.add(observation("video", 0.0))
        await synchronizer.add(observation("gps", 0.5))
        await synchronizer.add(observation("video", 0.2))
        await synchronizer.add(observation("gps", 0.1))
        await synchronizer.add(observation("video", 0.4))

        await synchronizer.flush()
        await synchronizer.stop()

        var released: [TimeInterval] = []
        for await observation in synchronizer.observations {
            released.append(observation.phenomenonTime.timeIntervalSince1970)
        }

        #expect(released == released.sorted())
        #expect(released.count == 5)
    }

    @Test("Nothing is released before the buffer window has passed")
    func holdsUntilTheWindowPasses() async throws {
        let synchronizer = TimeSynchronizer(bufferMillis: 1000)
        await synchronizer.start()

        // All within the window, so none may be released yet.
        for offset in [0.0, 0.1, 0.2] {
            await synchronizer.add(observation("gps", offset))
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(await synchronizer.bufferedCount == 3)

        // One far enough ahead pushes the frontier past the earlier three.
        await synchronizer.add(observation("gps", 5.0))
        try await Task.sleep(for: .milliseconds(120))
        #expect(await synchronizer.bufferedCount == 1)

        await synchronizer.stop()
    }

    @Test("An observation older than the frontier is dropped when discarding")
    func dropsOutdated() async throws {
        let synchronizer = TimeSynchronizer(bufferMillis: 100, discardOutdated: true)
        await synchronizer.start()

        await synchronizer.add(observation("gps", 0.0))
        await synchronizer.add(observation("gps", 10.0))
        try await Task.sleep(for: .milliseconds(120))

        // Arriving a full ten seconds late, well behind what was released.
        await synchronizer.add(observation("gps", 0.5))
        try await Task.sleep(for: .milliseconds(60))

        await synchronizer.stop()
        #expect(await synchronizer.bufferedCount <= 1)
    }

    @Test("Keeping outdated observations retains them instead")
    func keepsOutdatedWhenAsked() async throws {
        let synchronizer = TimeSynchronizer(bufferMillis: 100, discardOutdated: false)
        await synchronizer.add(observation("gps", 10.0))
        await synchronizer.add(observation("gps", 0.5))
        #expect(await synchronizer.bufferedCount == 2)
        await synchronizer.stop()
    }
}
