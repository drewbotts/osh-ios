import Foundation
import Combine
import Network

// MARK: - ObservationPublisher
//
// Owns delivery of *scalar* observations (GPS, orientation, barometer, audio) to
// the OSH node. Video never passes through here — a single H.264 frame is orders
// of magnitude larger than a scalar record, so buffering or batching frames would
// blow the ring buffer and add latency. VideoOutput posts frames directly via its
// `directPoster` hook instead; subscribe(to:) skips any module whose encoding
// contains a binary block field.
//
// Delivery pipeline:
//
//   sensor publisher → enqueue → per-datastream batch
//                                   │
//                     flush every 250 ms, or immediately at 50 records
//                                   │
//                     POST /datastreams/{id}/observations  (JSON array)
//                                   │
//                          success ─┴─ failure → ring buffer + backoff probe
//
// Ring buffer: fixed capacity 1000; oldest items dropped when full (keeping the
// most-recent data is preferred over unbounded growth or backpressure).
//
// Server-down recovery: any POST failure marks the publisher disconnected and
// starts an exponential-backoff probe (1s, 2s, 4s … capped at 30s) that calls
// testConnectivity(). Once the server answers, the buffer drains.

actor ObservationPublisher {

    /// Snapshot of publisher health, delivered over `status`.
    typealias Status = (isConnected: Bool, queuedCount: Int, sentCount: Int, errorCount: Int)

    // MARK: Tunables

    /// Maximum time a scalar observation waits in a batch before being POSTed.
    static let batchInterval: Duration = .milliseconds(250)
    /// Batch size that triggers an immediate flush without waiting for the ticker.
    static let maxBatchSize = 50
    /// Ceiling for the reconnect backoff delay.
    static let maxBackoff: Duration = .seconds(30)

    // MARK: State

    private var isConnected = false
    private var sentCount = 0
    private var errorCount = 0

    private var client: ConnectedSystemsClient?
    private var systemId: String?
    private var datastreamIds: [String: String] = [:]        // outputName → datastreamId
    private var datastreamSchemas: [String: DataRecord] = [:] // outputName → schema

    private var subscriptions = Set<AnyCancellable>()
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "osh.network.monitor")

    private let ringBuffer = RingBuffer<Observation>(capacity: 1000)
    private var isDraining = false

    /// Pending, not-yet-POSTed observations keyed by datastream output name.
    private var batches: [String: [Observation]] = [:]

    private var flushTicker: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var statusContinuations: [UUID: AsyncStream<Status>.Continuation] = [:]

    // MARK: Setup

    func configure(client: ConnectedSystemsClient,
                   systemId: String,
                   datastreamIds: [String: String],
                   datastreamSchemas: [String: DataRecord]) {
        self.client = client
        self.systemId = systemId
        self.datastreamIds = datastreamIds
        self.datastreamSchemas = datastreamSchemas
    }

    /// Subscribes to every *scalar* module's publisher and starts the flush ticker.
    /// Video modules are skipped — see the type comment.
    func subscribe(to modules: [SensorModule]) {
        for module in modules {
            guard !Self.isBinaryBlockEncoded(module.recommendedEncoding) else {
                Log.api.debug("Skipping binary-block module \(module.outputName, privacy: .public) — posts directly")
                continue
            }
            subscriptions.insert(Self.makeSink(for: module, target: self))
        }
        startFlushTicker()
    }

    /// Builds the Combine sink for one module.
    ///
    /// Deliberately `nonisolated static`: Combine's `sink(receiveValue:)` takes a
    /// plain escaping (non-@Sendable) closure, so building it inside an isolated
    /// method would hand the actor's own isolation region to escaping code.
    /// Building it here means the closure only ever captures `target`, an
    /// ordinary Sendable actor reference it hops onto with `await`.
    private nonisolated static func makeSink(for module: SensorModule,
                                             target: ObservationPublisher) -> AnyCancellable {
        module.publisher.sink { observation in
            Task { await target.enqueue(observation) }
        }
    }

    /// True when the encoding contains a BinaryBlock field, i.e. this is a video
    /// (or otherwise large-blob) datastream that must bypass the batching path.
    private static func isBinaryBlockEncoded(_ encoding: BinaryEncoding) -> Bool {
        encoding.fields.contains { if case .block = $0.type { return true }; return false }
    }

    func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { await self?.handleNetworkChange(connected: connected) }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    func stopAll() {
        pathMonitor.cancel()
        subscriptions.removeAll()
        flushTicker?.cancel()
        flushTicker = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        batches.removeAll()
        for continuation in statusContinuations.values { continuation.finish() }
        statusContinuations.removeAll()
    }

    // MARK: Status stream

    /// A new stream of health snapshots. Each access returns an independent stream
    /// that immediately yields the current status, then one value per change.
    /// The stream finishes when `stopAll()` is called.
    var status: AsyncStream<Status> {
        // bufferingNewest(1): a status snapshot is a full replacement, not an
        // event to replay — a slow consumer should see the latest state, not a
        // backlog of superseded ones.
        let (stream, continuation) = AsyncStream<Status>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        statusContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStatusContinuation(id) }
        }
        continuation.yield(currentStatus)
        return stream
    }

    private func removeStatusContinuation(_ id: UUID) {
        statusContinuations.removeValue(forKey: id)
    }

    private var currentStatus: Status {
        (isConnected: isConnected,
         queuedCount: ringBuffer.count + batches.values.reduce(0) { $0 + $1.count },
         sentCount: sentCount,
         errorCount: errorCount)
    }

    private func notifyStatus() {
        let snapshot = currentStatus
        for continuation in statusContinuations.values { continuation.yield(snapshot) }
    }

    // MARK: Network change

    private func handleNetworkChange(connected: Bool) async {
        guard connected != isConnected else { return }
        isConnected = connected
        if connected {
            // The path came back; a server-down probe is no longer the authority.
            reconnectTask?.cancel()
            reconnectTask = nil
            notifyStatus()
            await drainBuffer()
        } else {
            notifyStatus()
        }
    }

    // MARK: Enqueue / batching

    private func enqueue(_ obs: Observation) async {
        // Defensive: video is filtered out in subscribe(to:), but never let a
        // frame-sized payload into the batch/ring path.
        guard case .scalar = obs.payload else { return }

        batches[obs.datastreamName, default: []].append(obs)
        if batches[obs.datastreamName]?.count ?? 0 >= Self.maxBatchSize {
            await flush(datastreamName: obs.datastreamName)
        }
        // No status notification here on purpose: enqueue runs at sensor rate
        // (20 Hz with both orientation outputs enabled) and a pending batch is
        // gone within 250 ms. Status is published from flush/drain and on
        // connection changes, which is the rate the UI actually needs.
    }

    private func startFlushTicker() {
        guard flushTicker == nil else { return }
        flushTicker = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.batchInterval)
                } catch {
                    return  // cancelled
                }
                await self?.flushAll()
            }
        }
    }

    private func flushAll() async {
        for name in batches.keys where !(batches[name]?.isEmpty ?? true) {
            await flush(datastreamName: name)
        }
        await drainBuffer()
    }

    /// POSTs the pending batch for one datastream as a single JSON array.
    /// On failure the whole batch goes to the ring buffer and recovery kicks in.
    private func flush(datastreamName: String) async {
        guard let batch = batches[datastreamName], !batch.isEmpty else { return }
        batches[datastreamName] = []

        guard isConnected,
              let client,
              let datastreamId = datastreamIds[datastreamName] else {
            for obs in batch { ringBuffer.push(obs) }
            notifyStatus()
            return
        }

        do {
            try await client.postObservations(datastreamId: datastreamId,
                                              observations: batch,
                                              schema: datastreamSchemas[datastreamName])
            sentCount += batch.count
        } catch {
            errorCount += 1
            Log.api.error("Batch POST failed for \(datastreamName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            for obs in batch { ringBuffer.push(obs) }
            handleSendFailure()
        }
        notifyStatus()
    }

    // MARK: Drain

    private func drainBuffer() async {
        guard isConnected, !isDraining, !ringBuffer.isEmpty else { return }
        isDraining = true
        defer { isDraining = false }

        while isConnected, !ringBuffer.isEmpty {
            // Pull one batch worth and regroup by datastream — the buffer is
            // interleaved because several sensors share it.
            var grouped: [String: [Observation]] = [:]
            var taken = 0
            while taken < Self.maxBatchSize, let obs = ringBuffer.pop() {
                grouped[obs.datastreamName, default: []].append(obs)
                taken += 1
            }

            for (name, observations) in grouped {
                guard let client, let datastreamId = datastreamIds[name] else { continue }
                do {
                    try await client.postObservations(datastreamId: datastreamId,
                                                      observations: observations,
                                                      schema: datastreamSchemas[name])
                    sentCount += observations.count
                } catch {
                    errorCount += 1
                    Log.api.error("Drain POST failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    // Put them back at the front so ordering is preserved.
                    for obs in observations.reversed() { ringBuffer.pushFront(obs) }
                    handleSendFailure()
                    notifyStatus()
                    return
                }
            }
            notifyStatus()
        }
    }

    // MARK: Server-down recovery

    /// Marks the publisher disconnected and starts the backoff probe.
    /// Distinct from a network-path change: the path can be satisfied while the
    /// OSH node itself is down or restarting.
    private func handleSendFailure() {
        isConnected = false
        startReconnectBackoff()
    }

    private func startReconnectBackoff() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            var delay: Duration = .seconds(1)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return  // cancelled
                }
                guard let self else { return }
                if await self.probeServer() { return }
                delay = min(delay * 2, Self.maxBackoff)
            }
        }
    }

    /// One reachability probe. Returns true once the server answers, after which
    /// the publisher is marked connected and the buffer is drained.
    private func probeServer() async -> Bool {
        guard let client else { return false }
        Log.api.debug("Probing OSH node after send failure")
        guard await client.testConnectivity() == .connected else { return false }

        Log.api.info("OSH node reachable again — draining \(self.ringBuffer.count) buffered observations")
        isConnected = true
        reconnectTask = nil
        notifyStatus()
        await drainBuffer()
        return true
    }
}

// MARK: - Simple ring buffer

/// Fixed-capacity FIFO. When full, `push` drops the oldest element.
/// Not thread-safe on its own — it is only ever touched from inside
/// ObservationPublisher's actor isolation (and directly from unit tests).
final class RingBuffer<T> {
    private var storage: [T?]
    private var head = 0
    private var tail = 0
    private(set) var count = 0
    let capacity: Int

    var isEmpty: Bool { count == 0 }

    init(capacity: Int) {
        self.capacity = capacity
        self.storage  = Array(repeating: nil, count: capacity)
    }

    func push(_ item: T) {
        if count == capacity {
            // Drop oldest
            storage[head] = nil
            head = (head + 1) % capacity
            count -= 1
        }
        storage[tail] = item
        tail  = (tail + 1) % capacity
        count += 1
    }

    func pushFront(_ item: T) {
        guard count < capacity else { return }
        head = (head - 1 + capacity) % capacity
        storage[head] = item
        count += 1
    }

    func pop() -> T? {
        guard count > 0 else { return nil }
        let item = storage[head]
        storage[head] = nil
        head  = (head + 1) % capacity
        count -= 1
        return item
    }
}
