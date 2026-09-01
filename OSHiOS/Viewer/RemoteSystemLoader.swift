import Foundation

// MARK: - RemoteSystemLoader
//
// Turns a system id into a RemoteSystem: its datastreams, their schemas, its
// subsystems, its control streams and its deployment location.
//
// Two rules shape everything here.
//
// One datastream must never cost the system. A node with fourteen good streams
// and one the decoder trips over should render fourteen cards and an error
// badge, not an empty screen — so every per-datastream failure becomes a
// RemoteDatastream carrying its own error text.
//
// And a browse must not re-fetch what it just fetched. Scrolling a list of
// twelve systems, tapping into one and coming back would otherwise re-read
// every schema on the node; the cache is keyed per server so two configured
// nodes never see each other's entries.

actor RemoteSystemLoader {

    // MARK: Cache

    private struct CacheKey: Hashable {
        let serverId: UUID
        let systemId: String
    }

    private struct Entry {
        let system: RemoteSystem
        let loadedAt: Date
    }

    static let cacheTTL: TimeInterval = 300

    private var cache: [CacheKey: Entry] = [:]

    /// How many schema fetches run at once. Four keeps a browse quick without
    /// opening a socket per datastream on a node with forty of them.
    static let schemaConcurrency = 4

    // MARK: Loading

    /// Loads one system.
    ///
    /// - Parameter refresh: skip the cache. Pull-to-refresh passes true; row
    ///   appearance does not.
    /// - Returns: `.failure` only when the system itself could not be read.
    ///   Individual datastream problems arrive inside the RemoteSystem.
    func load(systemId: String,
              using client: ConnectedSystemsReadClient,
              serverId: UUID,
              refresh: Bool = false) async -> Result<RemoteSystem, Error> {

        let key = CacheKey(serverId: serverId, systemId: systemId)
        if !refresh, let entry = cache[key],
           Date().timeIntervalSince(entry.loadedAt) < Self.cacheTTL {
            return .success(entry.system)
        }

        do {
            let system = try await fetch(systemId: systemId, using: client)
            cache[key] = Entry(system: system, loadedAt: Date())
            return .success(system)
        } catch {
            Log.client.error("System \(systemId, privacy: .public) failed to load: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }

    /// Loads a whole listing, at most `concurrency` systems at once.
    ///
    /// Three surfaces now want every system on a node at once — the COP map,
    /// the video wall and the systems list — and each of them had grown its own
    /// copy of this task-group. Shared so that "how many schema fetches does
    /// opening a tab cost" has one answer.
    ///
    /// Systems that fail to load are dropped rather than represented: a listing
    /// entry with nothing behind it can neither be drawn on a map nor opened,
    /// and the per-system failure is already in the log.
    func loadAll(_ summaries: [SystemSummary],
                 using client: ConnectedSystemsReadClient,
                 serverId: UUID,
                 refresh: Bool = false,
                 concurrency: Int = 4) async -> [RemoteSystem] {

        var result: [Int: RemoteSystem] = [:]

        await withTaskGroup(of: (Int, RemoteSystem?).self) { group in
            var next = 0
            func add(_ index: Int) {
                let id = summaries[index].id
                group.addTask {
                    let outcome = await self.load(systemId: id, using: client,
                                                  serverId: serverId, refresh: refresh)
                    if case .success(let system) = outcome { return (index, system) }
                    return (index, nil)
                }
            }
            while next < summaries.count && next < concurrency {
                add(next); next += 1
            }
            while let (index, system) = await group.next() {
                result[index] = system
                if next < summaries.count { add(next); next += 1 }
            }
        }
        // Listing order, which is the order the node meant.
        return summaries.indices.compactMap { result[$0] }
    }

    /// Drops every cached system for one server — after a credential change,
    /// or when the user asks for a full refresh of a listing.
    func invalidate(serverId: UUID) {
        cache = cache.filter { $0.key.serverId != serverId }
    }

    // MARK: Fetching

    private func fetch(systemId: String,
                       using client: ConnectedSystemsReadClient) async throws -> RemoteSystem {

        let summary = try await client.getSystem(id: systemId)
        let datastreamSummaries = try await client.listDatastreams(systemId: systemId)

        // These three are independent of each other and of the schemas, and all
        // three tolerate absence, so they run together and none can fail the load.
        async let subsystems = (try? await client.listSubsystems(systemId: systemId)) ?? []
        async let controlStreams = Self.controlStreams(systemId: systemId, client: client)
        async let fixedLocation = try? await client.getSystemLocation(systemId: systemId)

        let datastreams = await resolveDatastreams(datastreamSummaries, using: client)

        return RemoteSystem(summary: summary,
                            subsystems: await subsystems,
                            datastreams: datastreams,
                            controlStreams: await controlStreams,
                            fixedLocation: await fixedLocation ?? nil)
    }

    /// Fetches every datastream's schema, at most `schemaConcurrency` at once,
    /// and puts the results back in listing order.
    ///
    /// Order matters more than it looks: the dashboard's card grid and the
    /// browser's badge counts are both read top-to-bottom, and a grid that
    /// reshuffled itself with network timing would be unusable.
    private func resolveDatastreams(_ summaries: [DatastreamSummary],
                                    using client: ConnectedSystemsReadClient) async
        -> [RemoteDatastream] {

        var resolved: [Int: RemoteDatastream] = [:]

        await withTaskGroup(of: (Int, RemoteDatastream).self) { group in
            var next = 0
            var running = 0

            func addTask(_ index: Int) {
                let summary = summaries[index]
                group.addTask {
                    (index, await Self.resolve(summary, using: client))
                }
            }

            while next < summaries.count && running < Self.schemaConcurrency {
                addTask(next)
                next += 1
                running += 1
            }

            while let (index, datastream) = await group.next() {
                resolved[index] = datastream
                if next < summaries.count {
                    addTask(next)
                    next += 1
                }
            }
        }

        return summaries.indices.compactMap { resolved[$0] }
    }

    private static func resolve(_ summary: DatastreamSummary,
                                using client: ConnectedSystemsReadClient) async -> RemoteDatastream {
        do {
            let decoder = try await client.makeDecoder(datastreamId: summary.id)
            return RemoteDatastream(summary: summary, schema: decoder.schema, decoder: decoder)
        } catch {
            // The message carries the failing path when the decoder produced
            // it — "invalid value at /img" is what makes an unfamiliar schema
            // diagnosable from the Logs tab.
            let message = error.localizedDescription
            Log.client.error("Schema for datastream \(summary.id, privacy: .public) (\(summary.outputName ?? "?", privacy: .public)) not understood: \(message, privacy: .public)")
            return RemoteDatastream(summary: summary, schemaError: message)
        }
    }

    /// `GET /systems/{id}/controlstreams`, each with its parameters schema.
    ///
    /// A node that models no commands answers 404 rather than an empty
    /// collection, exactly as it does for subsystems, so the whole listing
    /// degrades to "none" rather than failing the load.
    ///
    /// The schemas are fetched together for the same reason the datastream ones
    /// are: a camera with a PTZ control stream needs its DataChoice decoded
    /// before the video wall can decide whether to draw a D-pad over it, and a
    /// second round trip at that moment would show the controls a beat late.
    /// There are rarely more than one or two, so this is not throttled.
    private static func controlStreams(systemId: String,
                                       client: ConnectedSystemsReadClient) async
        -> [RemoteControlStream] {

        guard let summaries = try? await client.listControlStreams(systemId: systemId),
              !summaries.isEmpty else { return [] }

        var resolved: [Int: RemoteControlStream] = [:]
        await withTaskGroup(of: (Int, RemoteControlStream).self) { group in
            for (index, summary) in summaries.enumerated() {
                group.addTask { (index, await resolve(summary, using: client)) }
            }
            for await (index, stream) in group { resolved[index] = stream }
        }
        return summaries.indices.compactMap { resolved[$0] }
    }

    private static func resolve(_ summary: ControlStreamSummary,
                                using client: ConnectedSystemsReadClient) async
        -> RemoteControlStream {
        do {
            let data = try await client.getControlSchemaJSON(controlStreamId: summary.id)
            return RemoteControlStream(summary: summary,
                                       schema: try SWESchemaDecoder.decode(data))
        } catch {
            let message = error.localizedDescription
            Log.client.error("Control schema for \(summary.id, privacy: .public) (\(summary.inputName ?? "?", privacy: .public)) not understood: \(message, privacy: .public)")
            return RemoteControlStream(summary: summary, schemaError: message)
        }
    }
}
