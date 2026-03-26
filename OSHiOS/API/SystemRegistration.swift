import Foundation

// MARK: - SystemRegistration
//
// Wraps the one-time POST /api/systems call.
// Persists the returned systemId so it survives app restarts.
//
// On each start, if a cached id exists, we verify it still exists on the server
// (GET /systems/{id}).  If the server returns 404 (e.g. after a server restart),
// we clear the cache and re-register.

struct SystemRegistration {
    private static let defaultsKey = "osh.systemId"

    /// Returns a valid system id, registering with the server if necessary.
    static func registerIfNeeded(
        client: ConnectedSystemsClient,
        descriptor: SystemDescriptor
    ) async throws -> String {
        if let cached = UserDefaults.standard.string(forKey: defaultsKey),
           !cached.isEmpty {
            // Verify the cached id still exists on the server.
            let exists = try await client.systemExists(cached)
            if exists { return cached }
            // Server no longer has this system (e.g. server restarted) — re-register.
            clearCachedId()
        }
        let id = try await client.registerSystem(descriptor)
        UserDefaults.standard.set(id, forKey: defaultsKey)
        return id
    }

    static func clearCachedId() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
