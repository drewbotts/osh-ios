import Foundation

// MARK: - SystemRegistration
//
// Wraps the one-time POST /api/systems call.
// Persists the returned systemId so it survives app restarts.
//
// Cache keys are scoped per server: "osh.<serverId>.systemId". Each OSH node
// hands out its own resource ids, so a single global key would hand a system id
// minted by server A to server B and produce spurious 404 / re-registration
// churn every time the user switches servers in Settings.
//
// On each start, if a cached id exists, we verify it still exists on the server
// (GET /systems/{id}).  If the server returns 404 (e.g. after a server restart),
// we clear the cache and re-register.

struct SystemRegistration {
    private static func defaultsKey(serverId: UUID) -> String {
        "osh.\(serverId.uuidString).systemId"
    }

    /// Returns a valid system id, registering with the server if necessary.
    static func registerIfNeeded(
        client: ConnectedSystemsClient,
        serverId: UUID,
        descriptor: SystemDescriptor
    ) async throws -> String {
        let key = defaultsKey(serverId: serverId)
        if let cached = UserDefaults.standard.string(forKey: key),
           !cached.isEmpty {
            // Verify the cached id still exists on the server.
            let exists = try await client.systemExists(cached)
            if exists { return cached }
            // Server no longer has this system (e.g. server restarted) — re-register.
            Log.api.info("Cached system id no longer on server — re-registering")
            clearCachedId(serverId: serverId)
        }
        let id = try await client.registerSystem(descriptor)
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    static func clearCachedId(serverId: UUID) {
        UserDefaults.standard.removeObject(forKey: defaultsKey(serverId: serverId))
    }
}
