import Foundation

// MARK: - DatastreamRegistration
//
// Wraps POST /api/systems/{id}/datastreams for each SensorModule.
// Caches datastreamId keyed by outputName to survive restarts.
//
// Cache keys are scoped per server: "osh.<serverId>.datastreamId.<outputName>",
// for the same reason as SystemRegistration — datastream ids are only meaningful
// on the node that issued them.
//
// On each start, if a cached id exists, we verify it still exists on the server
// (GET /datastreams/{id}).  If the server returns 404 (e.g. after a server restart),
// we clear that entry and re-register the datastream.

struct DatastreamRegistration {
    private static func keyPrefix(serverId: UUID) -> String {
        "osh.\(serverId.uuidString).datastreamId."
    }

    private static func defaultsKey(serverId: UUID, outputName: String) -> String {
        keyPrefix(serverId: serverId) + outputName
    }

    /// Registers (or reuses) the datastream for one sensor output.
    ///
    /// Takes the schema pieces rather than the SensorModule itself so that this
    /// stays a plain value-passing call — sensor modules are reference types with
    /// hardware-backed internals and have no business crossing into the client's
    /// concurrency domain.
    static func registerIfNeeded(
        client: ConnectedSystemsClient,
        serverId: UUID,
        systemId: String,
        outputName: String,
        schema: DataRecord,
        encoding: BinaryEncoding
    ) async throws -> String {
        let key = defaultsKey(serverId: serverId, outputName: outputName)
        if let cached = UserDefaults.standard.string(forKey: key), !cached.isEmpty {
            // Verify the cached id still exists on the server.
            let exists = try await client.datastreamExists(cached)
            if exists { return cached }
            // Server no longer has this datastream — re-register.
            Log.api.info("Cached datastream id for \(outputName, privacy: .public) no longer on server — re-registering")
            UserDefaults.standard.removeObject(forKey: key)
        }
        let id = try await client.registerDatastream(
            systemId: systemId,
            name: outputName,
            schema: schema,
            encoding: encoding
        )
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    static func clearCachedIds(serverId: UUID) {
        let prefix = keyPrefix(serverId: serverId)
        let allKeys = UserDefaults.standard.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix(prefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
