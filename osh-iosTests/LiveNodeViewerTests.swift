import Testing
import Foundation
import CoreLocation
@testable import osh_ios

// MARK: - LiveNodeViewerTests
//
// The viewer against a real node. Skipped entirely unless OSH_NODE is set, like
// every other live test — the fixtures are the source of truth and these exist
// to catch the node changing under us.
//
// What they are actually checking is that nothing about a real node is fatal.
// A wholesale failure to load a system is a bug; a single unreadable schema is
// a fact about the node, printed rather than failed.

@Suite("Live node viewer", .enabled(if: LiveNode.isConfigured))
struct LiveNodeViewerTests {

    // MARK: Loading

    @Test("Every system on the node loads, and the roles it produces are printed",
          .timeLimit(.minutes(5)))
    func everySystemLoads() async throws {
        let client = try LiveNode.readClient()
        let loader = RemoteSystemLoader()
        let serverId = UUID()

        let summaries = try await client.listSystems(limit: 200)
        #expect(!summaries.isEmpty)

        var failures: [String] = []
        var schemaErrors: [String] = []
        var rows: [String] = []

        for summary in summaries {
            let outcome = await loader.load(systemId: summary.id,
                                            using: client,
                                            serverId: serverId)
            guard case .success(let system) = outcome else {
                if case .failure(let error) = outcome {
                    failures.append("\(summary.id) (\(summary.name)): \(error)")
                }
                continue
            }

            let position = system.positionKind.map(String.init(describing:)) ?? "none"
            rows.append("""
                \(system.name) [\(system.id)] · position \(position) \
                · \(system.datastreams.count) datastreams \
                · \(system.controlStreamCount) control
                """)

            for datastream in system.datastreams {
                if let schemaError = datastream.schemaError {
                    schemaErrors.append("\(datastream.id) (\(datastream.name)): \(schemaError)")
                    continue
                }
                let entity = datastream.entityKeyPath.map { " · entity \($0)" } ?? ""
                let embedded = datastream.embeddedPosition
                    .map { " · position \($0.location.latitude)" } ?? ""
                rows.append("    \(datastream.name) [\(datastream.id)] "
                            + "→ \(datastream.role.label)\(entity)\(embedded)")
            }
        }

        LiveNode.report("── Node datastream roles ──")
        for row in rows { LiveNode.report(row) }
        if !schemaErrors.isEmpty {
            LiveNode.report("── Schemas not understood ──")
            for error in schemaErrors { LiveNode.report("    \(error)") }
        }

        // Individual schema failures are allowed and printed; a system that
        // fails outright is not, because that is the whole screen gone.
        #expect(failures.isEmpty,
                "systems that failed to load: \(failures.joined(separator: "; "))")
    }

    // MARK: Multi-entity streams

    @Test("An AIS stream separates vessels by MMSI",
          .timeLimit(.minutes(2)))
    @MainActor
    func aisProducesDistinctEntities() async throws {
        let client = try LiveNode.readClient()
        let loader = RemoteSystemLoader()

        // The AIS system is found by shape, not by name: a location datastream
        // whose schema declares an entity key is exactly what "many things on
        // one stream" means. Several streams on this node have that shape and
        // most are empty, so the freshest wins — an aid-to-navigation report
        // nobody has transmitted in months would prove nothing either way.
        var target: (system: RemoteSystem, datastream: RemoteDatastream, freshness: Date)?
        for summary in try await client.listSystems(limit: 200) {
            guard case .success(let system) = await loader.load(systemId: summary.id,
                                                                using: client,
                                                                serverId: UUID()) else { continue }
            for datastream in system.datastreams where datastream.entityKeyPath != nil {
                let end = datastream.summary.phenomenonTimeRange?.last
                let freshness = end.flatMap {
                    $0.caseInsensitiveCompare("now") == .orderedSame
                        ? Date.distantFuture : ISO8601DateFormatter.parse($0)
                } ?? .distantPast
                if target == nil || freshness > target!.freshness {
                    target = (system, datastream, freshness)
                }
            }
        }

        guard let target else {
            LiveNode.report("No multi-entity datastream on this node; nothing to check.")
            return
        }

        let connection = try NodeConnection(server: LiveNode.server())
        let session = SystemLiveSession(system: target.system, connection: connection)
        session.start(datastreamIds: [target.datastream.id])
        defer { session.stop() }

        // Twenty seconds of live traffic, or whatever the archive bootstrap
        // brought with it — on a quiet channel the archive is the answer.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if (session.latest[target.datastream.id]?.count ?? 0) >= 2 { break }
            try? await Task.sleep(for: .milliseconds(500))
        }

        let entities = session.latest[target.datastream.id] ?? [:]
        LiveNode.report("Entities on \(target.datastream.name): \(entities.keys.sorted())")
        if entities.count < 2 {
            LiveNode.report("""
                Only \(entities.count) entity seen in 20 s — the channel may be \
                quiet. Not a failure.
                """)
        }
        #expect(entities.keys.allSatisfy { !$0.isEmpty },
                "an entity-keyed stream must not bucket into the empty key")
    }

    // MARK: Direction finding

    @Test("A direction-finding station puts a rotated marker and a bearing line on the map",
          .timeLimit(.minutes(3)))
    @MainActor
    func directionFindingStationRenders() async throws {
        let client = try LiveNode.readClient()
        let loader = RemoteSystemLoader()

        // Every one of them, not the first: this node carries a laser
        // rangefinder whose azimuth is a bearing and a KrakenSDR whose whole
        // purpose is one, and the interesting case is the second.
        var stations: [RemoteSystem] = []
        for summary in try await client.listSystems(limit: 200) {
            guard case .success(let system) = await loader.load(systemId: summary.id,
                                                                using: client,
                                                                serverId: UUID()) else { continue }
            if !system.bearingDatastreams.isEmpty { stations.append(system) }
        }

        guard !stations.isEmpty else {
            LiveNode.report("No direction-finding system on this node; nothing to check.")
            return
        }

        let model = COPMapModel()
        let connection = try NodeConnection(server: LiveNode.server())
        await model.load(connection: connection)
        defer { model.stopAll() }

        // Give the bootstrap a moment: both the reported position and the LOB
        // come from a single archived observation each.
        try? await Task.sleep(for: .seconds(5))
        model.refreshAnnotations()

        for station in stations {
            LiveNode.report("Direction-finding system: \(station.name) [\(station.id)] "
                            + "· position \(station.positionKind.map(String.init(describing:)) ?? "none")")

            // A bearing output does not imply a position. A KrakenSDR's comes
            // from a settings record's stationConfig, with its rotation from
            // the heading beside it — the whole reason the location search
            // learned to recurse. A laser range finder's azimuth is a bearing
            // too, and its registration says nothing about where the phone
            // holding it is: nothing locates it, so nothing is drawn for it,
            // and that is the correct answer rather than a gap.
            guard station.hasPosition else {
                let orphans = model.markers.filter { $0.id.hasPrefix(station.id) }
                    .filter { !$0.id.contains("#target-") }
                let orphanLines = model.bearingLines.filter { line in
                    station.bearingDatastreams.contains { $0.id == line.id }
                }
                LiveNode.report("    nothing locates this system: "
                                + "\(orphans.count) own marker(s), \(orphanLines.count) LOB")
                #expect(orphans.isEmpty, "a system with no position must not get a marker")
                #expect(orphanLines.isEmpty, "a bearing line needs an origin")
                continue
            }

            let markers = model.markers.filter { $0.id.hasPrefix(station.id) }
            for marker in markers {
                LiveNode.report("""
                        marker \(marker.id) at \(marker.coordinate.latitude), \
                    \(marker.coordinate.longitude) \
                    heading \(marker.headingDegrees.map { String(format: "%.1f", $0) } ?? "none") \
                    kind \(marker.kind)
                    """)
            }
            #expect(!markers.isEmpty, "\(station.name) has a position but produced no marker")

            // The DOA stream emits only on detection, so a line depends on the
            // archive having anything at all. Counted, not required.
            let lines = model.bearingLines.filter { line in
                station.bearingDatastreams.contains { $0.id == line.id }
            }
            let hasArchive = station.bearingDatastreams.contains {
                ($0.summary.phenomenonTimeRange?.count ?? 0) >= 2
            }
            LiveNode.report("    \(lines.count) bearing line(s), archive present: \(hasArchive)")
            for line in lines {
                LiveNode.report("    from \(line.start.latitude),\(line.start.longitude) "
                                + "to \(line.end.latitude),\(line.end.longitude) "
                                + "as of \(line.observedAt)")
            }
            if hasArchive {
                #expect(!lines.isEmpty,
                        "\(station.name) has archived bearings but drew no line")
            }
        }
    }

    // MARK: Targets

    @Test("A target stream draws a marker at the target and a line from its source",
          .timeLimit(.minutes(3)))
    @MainActor
    func targetStreamDrawsALineFromItsSource() async throws {
        let client = try LiveNode.readClient()
        let loader = RemoteSystemLoader()

        var owners: [RemoteSystem] = []
        var everySystem: [RemoteSystem] = []
        for summary in try await client.listSystems(limit: 200) {
            guard case .success(let system) = await loader.load(systemId: summary.id,
                                                                using: client,
                                                                serverId: UUID()) else { continue }
            everySystem.append(system)
            if !system.targetDatastreams.isEmpty { owners.append(system) }
        }

        guard !owners.isEmpty else {
            LiveNode.report("No target stream on this node; nothing to check.")
            return
        }

        let model = COPMapModel()
        let connection = try NodeConnection(server: LiveNode.server())
        await model.load(connection: connection)
        defer { model.stopAll() }

        // One archived observation each for the target and for whatever locates
        // its source, both fetched on load.
        try? await Task.sleep(for: .seconds(5))
        model.refreshAnnotations()

        for owner in owners {
            for datastream in owner.targetDatastreams {
                LiveNode.report("Target stream: \(datastream.name) [\(datastream.id)] "
                                + "on \(owner.name) [\(owner.id)]")

                // The role's promise: the coordinates in the record are the
                // target's, so they must not have become this system's marker.
                #expect(datastream.embeddedPosition == nil,
                        "a target's coordinates must not be an embedded position")

                let targets = model.targets(system: owner, datastream: datastream)
                LiveNode.report("    \(targets.count) target(s) drawn")

                for target in targets {
                    let source = target.source
                    LiveNode.report("""
                            target at \(target.coordinate.latitude), \
                        \(target.coordinate.longitude) as of \(target.observedAt)
                            source \(source?.name ?? "none") \
                        [\(source?.systemId ?? "-")] by \
                        \(source?.resolution.rawValue ?? "-") \
                        at \(source?.coordinate.map { "\($0.latitude), \($0.longitude)" } ?? "no position")
                        """)

                    // A marker at the target, always.
                    #expect(model.markers.contains { $0.id == target.markerId },
                            "a designated target must have a marker")

                    // A line only when something locates the source, which is
                    // the honest fallback rather than a failure.
                    let line = model.targetLines.first { $0.id == target.markerId }
                    if let origin = source?.coordinate {
                        let drawn = try #require(line, "a located source must draw a line")
                        #expect(drawn.start.latitude == origin.latitude)
                        #expect(drawn.end.latitude == target.coordinate.latitude)

                        // Sanity on the geometry: a range finder reaches
                        // hundreds of metres, not hundreds of kilometres.
                        let metres = CLLocation(latitude: origin.latitude,
                                                longitude: origin.longitude)
                            .distance(from: CLLocation(latitude: target.coordinate.latitude,
                                                        longitude: target.coordinate.longitude))
                        LiveNode.report(String(format: "    source is %.0f m from the target",
                                                metres))
                    } else {
                        #expect(line == nil, "a line needs an origin")
                    }
                }
            }
        }
    }

    // MARK: Lifecycle

    /// A dashboard left behind in the navigation stack must not keep eight
    /// WebSockets open. The dealloc is the proof: a Task that captured the
    /// session strongly would keep it alive past `stop()`, and the weak
    /// reference below would still be non-nil.
    @Test("Stopping a session closes every stream and releases it",
          .timeLimit(.minutes(2)))
    @MainActor
    func sessionStopsCleanly() async throws {
        let client = try LiveNode.readClient()
        let loader = RemoteSystemLoader()

        var subject: RemoteSystem?
        for summary in try await client.listSystems(limit: 200) {
            guard case .success(let system) = await loader.load(systemId: summary.id,
                                                                using: client,
                                                                serverId: UUID()) else { continue }
            if system.datastreams.contains(where: { $0.decoder != nil }) {
                subject = system
                break
            }
        }
        let system = try #require(subject)
        let connection = try NodeConnection(server: LiveNode.server())

        weak var weakSession: SystemLiveSession?
        do {
            let session = SystemLiveSession(system: system, connection: connection)
            weakSession = session
            session.start()
            #expect(!session.streamState.isEmpty, "start() opened nothing")

            try? await Task.sleep(for: .seconds(3))
            session.stop()

            #expect(session.streamState.values.allSatisfy { $0 == .idle },
                    "a stopped session still reports live streams: \(session.streamState)")
            #expect(!session.isRunning)
        }

        // The stream's own connection loop lives a moment past stop(), so a
        // single turn of the runloop is not enough to see it go.
        for _ in 0..<20 where weakSession != nil {
            try? await Task.sleep(for: .milliseconds(200))
        }
        #expect(weakSession == nil, "SystemLiveSession outlived stop() — a task is retaining it")
    }

    // MARK: Anonymous access

    /// Pass 3b made credentials optional. When the environment supplies none,
    /// the whole suite has been running anonymously already — this says so
    /// explicitly rather than leaving it implied.
    @Test("An anonymous client sends no Authorization header")
    func anonymousClientSendsNoHeader() {
        #expect(BasicAuth.header(username: "", password: "") == nil)
        #expect(BasicAuth.header(username: "   ", password: "secret") == nil)
        #expect(BasicAuth.header(username: "admin", password: "") == "Basic YWRtaW46")
    }
}

// MARK: - Reporting

extension LiveNode {

    /// Prints, and also appends to the file named by TEST_RUNNER_OSH_REPORT
    /// when one is set.
    ///
    /// A test running in the simulator writes its stdout somewhere xcodebuild
    /// does not forward, and the point of these tests is as much the table they
    /// produce as the assertions they make. The simulator shares the host's
    /// filesystem, so a plain path is all that is needed.
    static func report(_ line: String) {
        print(line)
        guard let path = ProcessInfo.processInfo.environment["OSH_REPORT"],
              !path.isEmpty else { return }
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
