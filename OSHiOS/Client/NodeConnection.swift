import Foundation

// MARK: - NodeConnection
//
// One configured OSH node, and the two clients that talk to it. Before this
// existed every feature built its own ConnectedSystemsClient from a
// ServerConfig, which meant a session, a connectivity test and a datastream
// listing each opened their own URLSession against the same host. Views now ask
// the environment for the connection instead of assembling one.
//
// @MainActor: this is SwiftUI-facing observable state. The clients it owns are
// actors, so the work itself still happens off the main actor.

@MainActor
final class NodeConnection: ObservableObject {

    let server: ServerConfig
    let readClient: ConnectedSystemsReadClient
    let writeClient: ConnectedSystemsClient
    /// Commanding. Separate from writeClient because posting an observation and
    /// commanding a camera are different privileges on a node that models them,
    /// and because a command wants a much shorter timeout than a bulk post.
    let commandClient: CommandClient

    /// Result of the most recent connectivity check, or nil if none has run.
    @Published private(set) var reachability: ConnectivityResult?
    @Published private(set) var lastCheckedAt: Date?

    /// Guards against overlapping checks when the user taps repeatedly.
    @Published private(set) var isChecking = false

    init(server: ServerConfig) throws {
        self.server = server
        self.readClient  = try ConnectedSystemsReadClient(nodeURL: server.url,
                                                          username: server.username,
                                                          password: server.password)
        self.writeClient = try ConnectedSystemsClient(nodeURL: server.url,
                                                      username: server.username,
                                                      password: server.password)
        self.commandClient = try CommandClient(nodeURL: server.url,
                                               username: server.username,
                                               password: server.password)
    }

    func checkConnectivity() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let result = await writeClient.testConnectivity()
        reachability  = result
        lastCheckedAt = Date()

        switch result {
        case .connected:
            Log.client.info("Node \(self.server.label, privacy: .public) reachable")
        case .authenticationFailed:
            Log.client.error("Node \(self.server.label, privacy: .public) rejected credentials")
        case .unreachable(let message):
            Log.client.error("Node \(self.server.label, privacy: .public) unreachable: \(message, privacy: .public)")
        }
    }
}
