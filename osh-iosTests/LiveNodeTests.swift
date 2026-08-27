import Testing
import Foundation
@testable import osh_ios

// MARK: - LiveNodeTests
//
// Tests that talk to a real OpenSensorHub node. Every one is disabled unless
// OSH_NODE is set, so the default suite stays green — and fast — with no
// network at all. That is the whole point of the fixtures: these exist to catch
// the node changing under us, not to be the primary check.
//
//   OSH_NODE=http://host:8080/sensorhub/api xcodebuild test …
//
// OSH_TEST_USER / OSH_TEST_PASS are used as Basic credentials when both are
// set, and are never written anywhere.

@Suite("Live node", .enabled(if: LiveNode.isConfigured))
struct LiveNodeTests {

    // MARK: Read client

    @Test("Lists systems and datastreams")
    func listsSystems() async throws {
        let client = try LiveNode.readClient()
        let systems = try await client.listSystems(limit: 20)
        #expect(!systems.isEmpty)

        let datastreams = try await client.listDatastreams(systemId: try #require(systems.first).id)
        #expect(datastreams.allSatisfy { !$0.id.isEmpty })
    }

    @Test("Every datastream on the node builds a decoder")
    func everyDatastreamDecodes() async throws {
        let client = try LiveNode.readClient()
        var checked = 0
        var failures: [String] = []

        for system in try await client.listSystems(limit: 20) {
            for datastream in try await client.listDatastreams(systemId: system.id) {
                do {
                    _ = try await client.makeDecoder(datastreamId: datastream.id)
                    checked += 1
                } catch {
                    // Named rather than thrown, so one unusual schema reports
                    // itself instead of hiding every datastream after it.
                    failures.append("\(datastream.id) (\(datastream.outputName ?? "?")): \(error)")
                }
            }
        }

        #expect(checked > 0)
        #expect(failures.isEmpty, "schemas that failed to decode: \(failures.joined(separator: "; "))")
    }

    @Test("Fetches and decodes recent observations")
    func fetchesObservations() async throws {
        let client = try LiveNode.readClient()
        let datastream = try #require(try await LiveNode.scalarDatastream(client))

        let decoder = try await client.makeDecoder(datastreamId: datastream.id)
        let page = try await client.fetchObservations(datastreamId: datastream.id,
                                                      limit: 5,
                                                      decoder: decoder)
        #expect(!page.observations.isEmpty)
        for observation in page.observations {
            #expect(observation.phenomenonTime.timeIntervalSince1970.isFinite)
            #expect(!observation.orderedPaths.isEmpty)
        }
    }

    @Test("Subsystems and system location degrade to empty rather than throwing")
    func subsystemsAndLocation() async throws {
        let client = try LiveNode.readClient()
        let system = try #require(try await client.listSystems(limit: 5).first)

        // Both are "absent" on the reference node, and absent must not throw.
        _ = try await client.listSubsystems(systemId: system.id)
        _ = try await client.getSystemLocation(systemId: system.id)
    }

    // MARK: Live stream

    /// How long to wait for a live message.
    ///
    /// The spec's 15 s assumed a fast stream; the fastest scalar datastream on
    /// the reference node publishes about once a minute, so 15 s would fail on
    /// a perfectly healthy node. Ninety seconds is two of its publish
    /// intervals — long enough to be meaningful, short enough to notice.
    static let streamTimeout = 90

    @Test("A live stream delivers observations",
          .timeLimit(.minutes(3)))
    @MainActor
    func liveStreamDelivers() async throws {
        let client = try LiveNode.readClient()
        let datastream = try #require(try await LiveNode.liveDatastream(client))
        let decoder = try await client.makeDecoder(datastreamId: datastream.id)

        let connection = try NodeConnection(server: LiveNode.server())
        let stream = ObservationStream(connection: connection,
                                       datastreamId: datastream.id,
                                       decoder: decoder)
        stream.start()
        defer { stream.stop() }

        // Raced against a sleep rather than checked inside the loop: `for await`
        // parks until the next event, so a deadline tested in the loop body
        // never fires on a stream that has gone quiet — which is exactly the
        // failure this test exists to catch.
        let received = await withTaskGroup(of: [ParsedObservation]?.self) { group in
            group.addTask {
                for await event in stream.events {
                    if case .observations(let observations) = event.kind { return observations }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.streamTimeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }

        #expect(!received.isEmpty,
                """
                no observations from \(datastream.id) (\(datastream.outputName ?? "?")) \
                in \(Self.streamTimeout) s
                """)
        for observation in received {
            #expect(observation.phenomenonTime.timeIntervalSince1970.isFinite)
        }
    }
}

// MARK: - LiveNode

/// Node configuration read from the environment. Credentials are used to build
/// one Authorization header and are never logged or written to disk.
enum LiveNode {

    static var url: String? {
        guard let value = ProcessInfo.processInfo.environment["OSH_NODE"],
              !value.isEmpty else { return nil }
        return value
    }

    static var isConfigured: Bool { url != nil }

    static func server() throws -> ServerConfig {
        let environment = ProcessInfo.processInfo.environment
        guard let url else { throw LiveNodeError.notConfigured }
        return ServerConfig(label: "live",
                            url: url,
                            username: environment["OSH_TEST_USER"] ?? "",
                            password: environment["OSH_TEST_PASS"] ?? "")
    }

    static func readClient() throws -> ConnectedSystemsReadClient {
        let config = try server()
        return try ConnectedSystemsReadClient(nodeURL: config.url,
                                              username: config.username,
                                              password: config.password)
    }

    /// The first datastream that is not a binary-block stream — one whose
    /// observations are scalars a test can inspect field by field.
    static func scalarDatastream(_ client: ConnectedSystemsReadClient) async throws
        -> DatastreamSummary? {
        for system in try await client.listSystems(limit: 20) {
            for datastream in try await client.listDatastreams(systemId: system.id) {
                guard let decoder = try? await client.makeDecoder(datastreamId: datastream.id),
                      !decoder.isBinaryBlockStream else { continue }
                let page = try? await client.fetchObservations(datastreamId: datastream.id,
                                                               limit: 1,
                                                               decoder: decoder)
                if page?.observations.isEmpty == false { return datastream }
            }
        }
        return nil
    }

    /// A scalar datastream still being written to, so a live subscription will
    /// see something. An archive-only stream would sit silent for the whole
    /// timeout and fail a test about the socket rather than about the archive.
    ///
    /// Selected with `latest: true`, because the node orders observations
    /// ascending: asking for one without it returns the OLDEST record in the
    /// archive, which on this node is weeks old for every datastream and makes
    /// every stream look dead.
    static func liveDatastream(_ client: ConnectedSystemsReadClient) async throws
        -> DatastreamSummary? {
        var newest: (DatastreamSummary, Date)?

        for system in try await client.listSystems(limit: 20) {
            for datastream in try await client.listDatastreams(systemId: system.id) {
                guard let decoder = try? await client.makeDecoder(datastreamId: datastream.id),
                      !decoder.isBinaryBlockStream,
                      let page = try? await client.fetchObservations(datastreamId: datastream.id,
                                                                     latest: true,
                                                                     limit: 1,
                                                                     decoder: decoder),
                      let latest = page.observations.first?.phenomenonTime else { continue }
                if newest == nil || latest > newest!.1 { newest = (datastream, latest) }
            }
        }

        // Only worth subscribing to if it produced something in the last hour.
        guard let newest, newest.1 > Date().addingTimeInterval(-3600) else { return nil }
        return newest.0
    }

    enum LiveNodeError: Error { case notConfigured }
}
