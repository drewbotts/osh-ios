import Foundation

// MARK: - NodeConnectionStore
//
// Holds the NodeConnection for whichever server is currently selected, and
// rebuilds it when that selection changes. Injected from osh_iosApp and kept in
// sync with AppSettingsStore.activeServer.
//
// Rebuilding is keyed on the server's *contents*, not just its id: editing a
// live server's URL or password in Settings has to produce new clients, and
// keying on the id alone would silently keep talking to the old host.

@MainActor
final class NodeConnectionStore: ObservableObject {

    @Published private(set) var active: NodeConnection?

    /// Set when building a connection failed — an unparseable URL is the only
    /// way that happens, and Settings is where the user fixes it.
    @Published private(set) var lastError: String?

    /// Selects the server to connect to. Passing nil clears the connection.
    /// A no-op when the same server is already active.
    func select(server: ServerConfig?) {
        guard let server else {
            if active != nil { Log.client.info("Node connection cleared") }
            active = nil
            lastError = nil
            return
        }

        if let current = active.map(\.server), !Self.differs(current, server) { return }

        do {
            active = try NodeConnection(server: server)
            lastError = nil
            Log.client.info("Node connection ready for \(server.label, privacy: .public)")
        } catch {
            active = nil
            lastError = error.localizedDescription
            Log.client.error("Cannot connect to \(server.label, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// True when anything the clients were built from has changed.
    private static func differs(_ lhs: ServerConfig, _ rhs: ServerConfig) -> Bool {
        lhs.id != rhs.id
            || lhs.url != rhs.url
            || lhs.username != rhs.username
            || lhs.password != rhs.password
    }
}
