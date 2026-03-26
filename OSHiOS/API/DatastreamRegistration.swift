import Foundation

// MARK: - DatastreamRegistration
//
// Wraps POST /api/systems/{id}/datastreams for each SensorModule.
// Caches datastreamId keyed by outputName to survive restarts.
//
// On each start, if a cached id exists, we verify it still exists on the server
// (GET /datastreams/{id}).  If the server returns 404 (e.g. after a server restart),
// we clear that entry and re-register the datastream.

struct DatastreamRegistration {
    private static func defaultsKey(for outputName: String) -> String {
        "osh.datastreamId.\(outputName)"
    }

    static func registerIfNeeded(
        client: ConnectedSystemsClient,
        systemId: String,
        module: SensorModule
    ) async throws -> String {
        let key = defaultsKey(for: module.outputName)
        if let cached = UserDefaults.standard.string(forKey: key), !cached.isEmpty {
            // Verify the cached id still exists on the server.
            let exists = try await client.datastreamExists(cached)
            if exists { return cached }
            // Server no longer has this datastream — re-register.
            UserDefaults.standard.removeObject(forKey: key)
        }
        let id = try await client.registerDatastream(
            systemId: systemId,
            name: module.outputName,
            schema: module.recordDescription,
            encoding: module.recommendedEncoding
        )
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    static func clearCachedIds() {
        let prefix = "osh.datastreamId."
        let allKeys = UserDefaults.standard.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix(prefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
