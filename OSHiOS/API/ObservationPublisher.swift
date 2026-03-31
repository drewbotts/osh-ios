import Foundation
import Combine
import Network

// MARK: - ObservationPublisher
//
// Subscribes to all SensorModule Combine publishers, buffers observations when
// the network is unavailable, and drains the buffer on reconnect.
//
// Ring buffer: fixed capacity; oldest items dropped when full (matches common
// embedded sensor patterns — keeping most-recent data is preferred over backpressure).

@MainActor
final class ObservationPublisher: ObservableObject {

    // MARK: State

    @Published private(set) var isConnected = false
    @Published private(set) var queuedCount = 0

    // MARK: Private

    private var client: ConnectedSystemsClient?
    private var systemId: String?
    private var datastreamIds: [String: String] = [:]      // outputName → datastreamId
    private var datastreamSchemas: [String: DataRecord] = [:] // outputName → schema

    private var subscriptions = Set<AnyCancellable>()
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "osh.network.monitor")

    private let ringBuffer = RingBuffer<Observation>(capacity: 1000)
    private var isDraining = false

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

    func subscribe(to modules: [SensorModule]) {
        for module in modules {
            module.publisher
                .receive(on: DispatchQueue.global(qos: .utility))
                .sink { [weak self] obs in
                    self?.enqueue(obs)
                }
                .store(in: &subscriptions)
        }
    }

    /// Merges additional datastream ids and schemas into the publisher's routing tables.
    /// Used to add Garmin (or other late-registered) outputs after initial configure().
    func addDatastreams(ids: [String: String], schemas: [String: DataRecord]) {
        datastreamIds.merge(ids) { _, new in new }
        datastreamSchemas.merge(schemas) { _, new in new }
    }

    /// Subscribe to Garmin sensor outputs. Delegates to subscribe(to:) so all
    /// Garmin observations share the same ring buffer and drain logic.
    func subscribeGarmin(to outputs: [SensorModule]) {
        subscribe(to: outputs)
    }

    func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.handleNetworkChange(connected: connected)
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    func stopAll() {
        pathMonitor.cancel()
        subscriptions.removeAll()
    }

    // MARK: Network change

    private func handleNetworkChange(connected: Bool) {
        isConnected = connected
        if connected {
            Task { [weak self] in await self?.drainBuffer() }
        }
    }

    // MARK: Enqueue

    private func enqueue(_ obs: Observation) {
        if isConnected && !isDraining && ringBuffer.isEmpty {
            // Fast path: post directly without buffering
            Task { [weak self] in await self?.send(obs) }
        } else {
            ringBuffer.push(obs)
            Task { @MainActor [weak self] in self?.queuedCount = self?.ringBuffer.count ?? 0 }
            if isConnected && !isDraining {
                Task { [weak self] in await self?.drainBuffer() }
            }
        }
    }

    // MARK: Drain

    private func drainBuffer() async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        while let obs = ringBuffer.pop() {
            await send(obs)
            await MainActor.run { queuedCount = ringBuffer.count }
        }
    }

    private func send(_ obs: Observation) async {
        guard let client = client,
              let datastreamId = datastreamIds[obs.datastreamName] else { return }
        let schema = datastreamSchemas[obs.datastreamName]
        do {
            try await client.postObservation(datastreamId: datastreamId,
                                             observation: obs,
                                             schema: schema)
        } catch {
            // On failure re-queue at front (best effort; ring buffer may discard if full)
            ringBuffer.pushFront(obs)
            isConnected = false
        }
    }
}

// MARK: - Simple ring buffer

private final class RingBuffer<T> {
    private var storage: [T?]
    private var head = 0
    private var tail = 0
    private(set) var count = 0
    private let capacity: Int

    var isEmpty: Bool { count == 0 }

    init(capacity: Int) {
        self.capacity = capacity
        self.storage  = Array(repeating: nil, count: capacity)
    }

    func push(_ item: T) {
        if count == capacity {
            // Drop oldest
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
