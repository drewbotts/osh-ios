import Foundation
import Combine

// MARK: - VideoWallModel
//
// Every camera on the node, on one screen.
//
// The hard part is not the grid — it is that a wall of cameras is the one view
// that can trivially exhaust a phone. Each MJPEG stream is a WebSocket, a
// decode per frame and a CGImage held in memory, and a node with nine cameras
// would try to run nine of them the moment the tab appeared.
//
// So there is a hard cap of four playing streams, enforced round-robin: asking
// for a fifth pauses the one that has been playing longest rather than refusing
// the request. That ordering is deliberate. A user tapping a fifth tile wants
// that tile, and the tile they stopped looking at first is the one they will
// miss least.
//
// Sessions are per system rather than per datastream, because SystemLiveSession
// is what owns the decode and the arrival statistics, and a camera system with
// two outputs should hold one socket set, not two.

@MainActor
final class VideoWallModel: ObservableObject {

    // MARK: Types

    /// One tile: a video datastream and the system it belongs to.
    struct Tile: Identifiable, Equatable {
        let systemId: String
        let systemName: String
        let datastreamId: String
        let datastreamName: String
        let compression: String?
        /// True when this app can turn the frames into pictures.
        let isDecodable: Bool

        var id: String { datastreamId }

        static func == (lhs: Tile, rhs: Tile) -> Bool { lhs.id == rhs.id }
    }

    // MARK: Configuration

    /// How many MJPEG streams may play at once.
    static let maxPlaying = 4

    /// Systems loaded at once when the tab appears.
    static let loadConcurrency = 4

    // MARK: Published state

    @Published private(set) var tiles: [Tile] = []
    @Published private(set) var systems: [RemoteSystem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    /// Datastream ids currently subscribed, oldest first — the pause order.
    @Published private(set) var playing: [String] = []

    // MARK: Private state

    private let loader = RemoteSystemLoader()
    private var sessions: [String: SystemLiveSession] = [:]
    private var observers: [String: AnyCancellable] = [:]
    private var connection: NodeConnection?

    // MARK: Loading

    func load(connection: NodeConnection?, refresh: Bool = false) async {
        self.connection = connection
        guard let connection else {
            stopAll()
            tiles = []
            systems = []
            error = "Select a server on the Systems tab first."
            return
        }

        isLoading = true
        defer { isLoading = false }

        if refresh {
            await loader.invalidate(serverId: connection.server.id)
            stopAll()
        }

        do {
            let summaries = try await connection.readClient.listSystems(limit: 200)
            systems = await loader.loadAll(summaries,
                                           using: connection.readClient,
                                           serverId: connection.server.id,
                                           refresh: refresh,
                                           concurrency: Self.loadConcurrency)
            tiles = Self.tiles(in: systems)
            for system in systems {
                ActivityTracker.shared.seed(system.activity,
                                            serverId: connection.server.id,
                                            systemId: system.id)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            Log.client.error("Video wall listing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Every video datastream on the node, in listing order.
    static func tiles(in systems: [RemoteSystem]) -> [Tile] {
        systems.flatMap { system in
            system.datastreams.compactMap { datastream -> Tile? in
                guard case .video(let compression) = datastream.role else { return nil }
                guard datastream.decoder != nil else { return nil }
                return Tile(systemId: system.id,
                            systemName: system.name,
                            datastreamId: datastream.id,
                            datastreamName: datastream.name,
                            compression: compression,
                            isDecodable: MJPEGDecoder.canDecode(compression: compression))
            }
        }
    }

    // MARK: Playback

    func isPlaying(_ tile: Tile) -> Bool { playing.contains(tile.datastreamId) }

    /// Opens a tile's stream, pausing the longest-playing one if the wall is
    /// already full.
    func play(_ tile: Tile) {
        guard let connection, !playing.contains(tile.datastreamId) else { return }
        guard let system = systems.first(where: { $0.id == tile.systemId }) else { return }

        if playing.count >= Self.maxPlaying, let oldest = playing.first {
            Log.client.info("Video wall at capacity; pausing \(oldest, privacy: .public) for \(tile.datastreamId, privacy: .public)")
            pause(datastreamId: oldest)
        }

        let session = sessions[tile.systemId] ?? {
            let created = SystemLiveSession(system: system, connection: connection)
            sessions[tile.systemId] = created
            observers[tile.systemId] = created.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
            return created
        }()

        session.start(datastreamId: tile.datastreamId)
        playing.append(tile.datastreamId)
    }

    func pause(_ tile: Tile) { pause(datastreamId: tile.datastreamId) }

    private func pause(datastreamId: String) {
        guard let index = playing.firstIndex(of: datastreamId) else { return }
        playing.remove(at: index)
        guard let tile = tiles.first(where: { $0.datastreamId == datastreamId }) else { return }
        sessions[tile.systemId]?.stop(datastreamId: datastreamId)
        releaseSessionIfIdle(systemId: tile.systemId)
    }

    /// Starts every tile the autoplay setting permits, up to the cap.
    ///
    /// H.264 tiles are included: they decode to nothing yet, but their arrival
    /// figures are the only way to tell "not supported" from "not arriving",
    /// and those cost one socket rather than a decode per frame.
    func autoplay() {
        for tile in tiles where !isPlaying(tile) {
            guard playing.count < Self.maxPlaying else { return }
            play(tile)
        }
    }

    func stopAll() {
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        observers.removeAll()
        playing.removeAll()
    }

    /// Drops a session once nothing on it is playing, so a wall scrolled past
    /// does not keep a synchronizer and a release loop alive per camera.
    private func releaseSessionIfIdle(systemId: String) {
        let stillPlaying = tiles.contains {
            $0.systemId == systemId && playing.contains($0.datastreamId)
        }
        guard !stillPlaying else { return }
        sessions[systemId]?.stop()
        sessions[systemId] = nil
        observers[systemId] = nil
    }

    // MARK: Reading

    func session(for tile: Tile) -> SystemLiveSession? { sessions[tile.systemId] }

    func frame(_ tile: Tile) -> DecodedFrame? {
        sessions[tile.systemId]?.frames[tile.datastreamId]
    }

    func stats(_ tile: Tile) -> SystemLiveSession.BlockStats? {
        sessions[tile.systemId]?.blockStats[tile.datastreamId]
    }

    func system(_ tile: Tile) -> RemoteSystem? {
        systems.first { $0.id == tile.systemId }
    }

    func activityState(_ tile: Tile) -> ActivityState {
        guard let serverId = connection?.server.id else { return .offline }
        return ActivityTracker.shared.state(serverId: serverId, systemId: tile.systemId)
    }
}
