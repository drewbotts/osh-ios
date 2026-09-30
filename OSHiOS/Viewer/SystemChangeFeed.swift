import Foundation

// MARK: - SystemChangeFeed
//
// One place to say "this system's description just changed on the node".
//
// Three surfaces each hold their own RemoteSystemLoader and their own array of
// systems — the Systems list, the COP map and the video wall — and none of them
// can see the others' caches. When survey-in writes a position, every one of
// them would otherwise keep drawing the old one for up to five minutes, which
// is exactly the "did it work?" moment the user is looking at the map for.
//
// A @MainActor singleton with one @Published value, observed the same way the
// models already observe ActivityTracker. Not NotificationCenter: its payload
// is an untyped dictionary and its `Notification` is not Sendable, and this
// codebase has one convention for cross-surface state already.

@MainActor
final class SystemChangeFeed: ObservableObject {

    static let shared = SystemChangeFeed()

    struct Change: Equatable, Sendable {
        let serverId: UUID
        let systemId: String
        let at: Date
    }

    /// The most recent change. Consumers compare `at` (or just react to every
    /// publication) rather than the id, so two edits to one system both land.
    @Published private(set) var lastChange: Change?

    func publish(serverId: UUID, systemId: String) {
        lastChange = Change(serverId: serverId, systemId: systemId, at: Date())
        Log.client.info("System \(systemId, privacy: .public) description changed; surfaces will reload it")
    }
}
