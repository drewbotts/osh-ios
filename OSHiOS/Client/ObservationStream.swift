import Foundation

// MARK: - ObservationStream
//
// A live WebSocket subscription to one datastream, decoded on the way in.
//
// The node's observations endpoint serves the same URL over HTTP and over
// WebSocket, distinguished only by the Upgrade handshake, so the stream URL is
// the REST one with its scheme swapped. Messages arrive already framed — one
// observation per message — which is why a binary message can be handed
// straight to the decoder without any record-splitting.
//
// Reconnection is the stream's own business rather than the caller's: a node
// restart, a Wi-Fi handover or a laptop lid closing all present as a socket
// error, and a viewer that had to re-subscribe after each would be unusable.

final class ObservationStream: Sendable {

    // MARK: Events

    struct Event: Sendable {
        enum Kind: Sendable {
            case connected
            case disconnected(Error?)
            case observations([ParsedObservation])
        }
        let datastreamId: String
        let kind: Kind
    }

    // MARK: Stored

    let datastreamId: String

    private let url: URL
    private let authHeader: String
    private let decoder: DatastreamDecoder
    private let format: String
    private let state: StreamState

    private let stream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    /// Events from this subscription. A single consumer is assumed.
    var events: AsyncStream<Event> { stream }

    // MARK: Init

    /// - Parameters:
    ///   - replay: a time range and speed multiplier to replay archived
    ///     observations instead of following the live edge.
    init(connection: NodeConnection,
         datastreamId: String,
         decoder: DatastreamDecoder,
         format: String? = nil,
         replay: (range: ClosedRange<Date>, speed: Double)? = nil) {

        self.datastreamId = datastreamId
        self.decoder = decoder
        self.format = format ?? decoder.preferredStreamFormat
        self.state = StreamState()

        let server = connection.server
        self.authHeader = "Basic " + Data("\(server.username):\(server.password)".utf8)
            .base64EncodedString()
        self.url = Self.streamURL(base: server.url,
                                  datastreamId: datastreamId,
                                  format: self.format,
                                  replay: replay)

        (self.stream, self.continuation) = AsyncStream<Event>.makeStream(
            bufferingPolicy: .bufferingNewest(64))
    }

    /// Builds ws://…/datastreams/{id}/observations?f=… from the REST base URL.
    private static func streamURL(base: String,
                                  datastreamId: String,
                                  format: String,
                                  replay: (range: ClosedRange<Date>, speed: Double)?) -> URL {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard var components = URLComponents(string: trimmed) else {
            // The base came from a server the user already connected with, so
            // an unparseable one is caught by the connectivity check long
            // before a stream is opened.
            return URL(fileURLWithPath: "/")
        }

        // https must become wss, not ws: silently downgrading a secure node to
        // a plaintext socket would leak the credentials in the handshake.
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path += "/datastreams/\(datastreamId)/observations"

        var query = [URLQueryItem(name: "f", value: format)]
        if let replay {
            query.append(URLQueryItem(
                name: "phenomenonTime",
                value: "\(iso(replay.range.lowerBound))/\(iso(replay.range.upperBound))"))
            query.append(URLQueryItem(name: "replaySpeed", value: String(replay.speed)))
        }
        components.setQueryItemsEncodingPlus(query)

        return components.url ?? URL(fileURLWithPath: "/")
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    // MARK: Lifecycle

    func start() {
        Task { await state.start { [weak self] in await self?.runUntilStopped() } }
    }

    func stop() {
        Task {
            await state.stop()
            continuation.finish()
        }
    }

    // MARK: Connection loop

    /// Connects, reads until the socket fails, backs off, repeats.
    ///
    /// Backoff doubles from 1 s to a 30 s ceiling and resets on a successful
    /// connection, so a node that is briefly restarting is picked up quickly
    /// while one that is gone for the afternoon is not hammered.
    private func runUntilStopped() async {
        var backoff: UInt64 = 1

        while await state.isRunning {
            let session = URLSession(configuration: .default)
            var request = URLRequest(url: url)
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")

            let task = session.webSocketTask(with: request)
            await state.setTask(task)
            task.resume()

            Log.client.info("Stream \(self.datastreamId, privacy: .public) connecting as \(self.format, privacy: .public)")
            continuation.yield(Event(datastreamId: datastreamId, kind: .connected))

            let failure = await receiveLoop(task)

            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()

            guard await state.isRunning else { break }

            continuation.yield(Event(datastreamId: datastreamId, kind: .disconnected(failure)))
            Log.client.info("Stream \(self.datastreamId, privacy: .public) disconnected, retrying in \(backoff)s")

            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 30)
        }

        Log.client.info("Stream \(self.datastreamId, privacy: .public) stopped")
        continuation.finish()
    }

    /// Reads messages until one fails. Returns the error that ended the loop.
    private func receiveLoop(_ task: URLSessionWebSocketTask) async -> Error? {
        while await state.isRunning {
            do {
                let message = try await task.receive()
                guard let observations = decode(message) else { continue }
                if !observations.isEmpty {
                    continuation.yield(Event(datastreamId: datastreamId,
                                             kind: .observations(observations)))
                }
            } catch {
                return error
            }
        }
        return nil
    }

    /// Decodes one message, or nil when it could not be read.
    ///
    /// A decode failure drops that message and keeps the subscription open: one
    /// malformed frame on a 10 Hz stream is not a reason to tear down a
    /// connection, and the Logs tab carries the path that failed.
    private func decode(_ message: URLSessionWebSocketTask.Message) -> [ParsedObservation]? {
        do {
            switch message {
            case .string(let text):
                return try decoder.decode(json: Data(text.utf8))

            case .data(let data):
                // A node may send JSON over a binary frame; the negotiated
                // format, not the frame type, decides how to read it.
                if format.localizedCaseInsensitiveContains("binary") {
                    return try decoder.decode(binary: data)
                }
                return try decoder.decode(json: data)

            @unknown default:
                return nil
            }
        } catch {
            Log.client.error("Stream \(self.datastreamId, privacy: .public) decode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

// MARK: - StreamState

/// The stream's mutable parts, isolated.
///
/// ObservationStream is Sendable and its socket task and running flag are
/// touched from the connection loop, from start() and from stop(); an actor is
/// what lets the class stay Sendable without any unchecked escape.
private actor StreamState {

    private(set) var isRunning = false
    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?

    func start(_ body: @escaping @Sendable () async -> Void) {
        guard !isRunning else { return }
        isRunning = true
        loop = Task { await body() }
    }

    func stop() {
        isRunning = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        loop?.cancel()
        loop = nil
    }

    func setTask(_ task: URLSessionWebSocketTask?) {
        self.task = task
    }
}
