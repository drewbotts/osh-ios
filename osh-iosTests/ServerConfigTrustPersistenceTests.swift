import Testing
import Foundation
@testable import osh_ios

// MARK: - ServerConfigTrustPersistenceTests
//
// Adding a field to a persisted record is where a settings screen quietly
// loses every server the user had configured. The stored metadata is written by
// KeychainServerStore as JSON in UserDefaults, so the test that matters is that
// a record written before the field existed still decodes.

@Suite("Server config trust persistence", .serialized)
struct ServerConfigTrustPersistenceTests {

    /// Matches KeychainServerStore's own key, which is private to it.
    private static let defaultsKey = "osh.serverConfigs"

    /// Saves and restores whatever the simulator already had, so running the
    /// suite does not wipe a hand-configured server.
    private func withStoredMetadata(_ json: String,
                                    _ body: (KeychainServerStore) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: Self.defaultsKey)
        defer {
            if let previous { defaults.set(previous, forKey: Self.defaultsKey) }
            else { defaults.removeObject(forKey: Self.defaultsKey) }
        }
        defaults.set(Data(json.utf8), forKey: Self.defaultsKey)
        try body(KeychainServerStore())
    }

    @Test("A record saved before the trust flag existed loads with it off")
    func legacyRecordDecodes() throws {
        let legacy = """
        [{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","label":"old node",\
        "description":"","url":"http://192.168.4.34:8080/sensorhub/api",\
        "username":"admin"}]
        """
        try withStoredMetadata(legacy) { store in
            let servers = store.loadAll()
            #expect(servers.count == 1)
            let server = try #require(servers.first)
            #expect(server.label == "old node")
            #expect(server.url == "http://192.168.4.34:8080/sensorhub/api")
            #expect(server.allowSelfSignedCertificates == false)
        }
    }

    @Test("A record saved with the flag on loads with it on")
    func currentRecordDecodes() throws {
        let current = """
        [{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","label":"tls node",\
        "description":"","url":"https://192.168.4.34:8443/sensorhub/api",\
        "username":"","allowSelfSignedCertificates":true}]
        """
        try withStoredMetadata(current) { store in
            let server = try #require(store.loadAll().first)
            #expect(server.allowSelfSignedCertificates == true)
        }
    }

    // MARK: Host derivation
    //
    // The delegate matches a certificate challenge against this, so a URL the
    // user typed with a path and port still has to yield the bare host.

    @Test("host strips scheme, port and path", arguments: [
        ("http://192.168.4.34:8080/sensorhub/api", "192.168.4.34"),
        ("https://100.102.179.24:8443/sensorhub/api", "100.102.179.24"),
        ("https://ogc-demo/sensorhub/api", "ogc-demo"),
        ("http://node.example.com", "node.example.com"),
    ])
    func hostDerivation(url: String, expected: String) {
        let config = ServerConfig(label: "n", url: url, username: "", password: "")
        #expect(config.host == expected)
    }
}
