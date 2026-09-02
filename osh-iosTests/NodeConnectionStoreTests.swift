import Testing
import Foundation
@testable import osh_ios

// MARK: - NodeConnectionStoreTests
//
// The store keeps one NodeConnection and rebuilds it when the selected server
// changes. Its clients capture their configuration at init — base URL, auth
// header, and the certificate-trust policy baked into their session delegate —
// so a field that changes without a rebuild is a setting the user can turn on
// with no effect at all. That is not hypothetical: allowSelfSignedCertificates
// shipped missing from the comparison and did exactly that.
//
// Identity is the assertion because a rebuild is the observable behaviour: a
// new NodeConnection instance means new clients, and the same instance means
// the old policy is still in force.

@Suite("Node connection store")
@MainActor
struct NodeConnectionStoreTests {

    private func server(url: String = "https://192.168.4.34:8443/sensorhub/api",
                        username: String = "",
                        password: String = "",
                        trust: Bool = false) -> ServerConfig {
        ServerConfig(id: Self.fixedId,
                     label: "node",
                     url: url,
                     username: username,
                     password: password,
                     allowSelfSignedCertificates: trust)
    }

    /// Shared so a change of id is never what triggers a rebuild in these tests.
    private static let fixedId = UUID()

    @Test("Turning certificate trust on rebuilds the connection")
    func trustChangeRebuilds() throws {
        let store = NodeConnectionStore()
        store.select(server: server(trust: false))
        let before = try #require(store.active)
        #expect(before.server.allowSelfSignedCertificates == false)

        store.select(server: server(trust: true))
        let after = try #require(store.active)
        #expect(after !== before)
        #expect(after.server.allowSelfSignedCertificates == true)
    }

    @Test("Turning it back off rebuilds too")
    func trustRevocationRebuilds() throws {
        let store = NodeConnectionStore()
        store.select(server: server(trust: true))
        let before = try #require(store.active)

        store.select(server: server(trust: false))
        let after = try #require(store.active)
        #expect(after !== before)
        #expect(after.server.allowSelfSignedCertificates == false)
    }

    @Test("Selecting an unchanged server keeps the same connection")
    func unchangedServerIsANoOp() throws {
        let store = NodeConnectionStore()
        store.select(server: server(trust: true))
        let before = try #require(store.active)

        store.select(server: server(trust: true))
        #expect(store.active === before)
    }

    @Test("Each field the clients are built from forces a rebuild", arguments: [
        "url", "username", "password", "trust",
    ])
    func everyClientFieldRebuilds(changed: String) throws {
        let store = NodeConnectionStore()
        store.select(server: server())
        let before = try #require(store.active)

        switch changed {
        case "url":      store.select(server: server(url: "http://192.168.4.34:8080/sensorhub/api"))
        case "username": store.select(server: server(username: "admin"))
        case "password": store.select(server: server(password: "secret"))
        default:         store.select(server: server(trust: true))
        }

        #expect(store.active !== before, "changing \(changed) did not rebuild the connection")
    }

    @Test("Clearing the selection drops the connection")
    func nilClears() {
        let store = NodeConnectionStore()
        store.select(server: server())
        store.select(server: nil)
        #expect(store.active == nil)
    }
}
