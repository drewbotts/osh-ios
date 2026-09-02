import Foundation
import Security

// MARK: - ServerConfig

struct ServerConfig: Codable, Identifiable {
    let id: UUID
    var label: String
    var description: String
    var url: String
    var username: String
    var password: String

    /// Accept this server's certificate even though it does not chain to a
    /// trusted root. Per server and off by default: an OSH node on a private
    /// network is commonly issued a self-signed certificate, and the user is
    /// the only one who can say that a given box is theirs.
    var allowSelfSignedCertificates: Bool

    init(id: UUID = UUID(),
         label: String,
         description: String = "",
         url: String,
         username: String,
         password: String,
         allowSelfSignedCertificates: Bool = false) {
        self.id          = id
        self.label       = label
        self.description = description
        self.url         = url
        self.username    = username
        self.password    = password
        self.allowSelfSignedCertificates = allowSelfSignedCertificates
    }

    /// Host of `url`, for matching a certificate challenge against the server
    /// the user actually configured.
    var host: String? { URLComponents(string: url)?.host }
}

// MARK: - KeychainServerStore
//
// Persists a list of ServerConfig values with passwords stored in Keychain.
// Everything except the password is saved as JSON in UserDefaults; each
// password is stored separately in Keychain keyed by config.id.uuidString.

final class KeychainServerStore {

    private static let defaultsKey     = "osh.serverConfigs"
    private static let keychainService = "osh.ios"

    // Codable metadata (no password) stored in UserDefaults
    private struct Metadata: Codable {
        let id: UUID
        var label: String
        var description: String
        var url: String
        var username: String
        /// Optional, not defaulted: a record written before this flag existed
        /// has no such key, and a non-optional Bool would fail the whole
        /// decode — losing every configured server rather than one setting.
        var allowSelfSignedCertificates: Bool?
    }

    // MARK: - Public API

    func save(_ config: ServerConfig) throws {
        savePassword(config.password, for: config.id)
        var records = loadMetadata()
        let meta = Metadata(id: config.id, label: config.label,
                            description: config.description,
                            url: config.url, username: config.username,
                            allowSelfSignedCertificates: config.allowSelfSignedCertificates)
        if let idx = records.firstIndex(where: { $0.id == config.id }) {
            records[idx] = meta
        } else {
            records.append(meta)
        }
        saveMetadata(records)
    }

    func delete(_ config: ServerConfig) throws {
        deletePassword(for: config.id)
        var records = loadMetadata()
        records.removeAll { $0.id == config.id }
        saveMetadata(records)
    }

    func loadAll() -> [ServerConfig] {
        loadMetadata().map { meta in
            ServerConfig(id: meta.id,
                         label: meta.label,
                         description: meta.description,
                         url: meta.url,
                         username: meta.username,
                         password: loadPassword(for: meta.id),
                         allowSelfSignedCertificates: meta.allowSelfSignedCertificates ?? false)
        }
    }

    func password(for config: ServerConfig) -> String {
        loadPassword(for: config.id)
    }

    // MARK: - UserDefaults helpers

    private func loadMetadata() -> [Metadata] {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let records = try? JSONDecoder().decode([Metadata].self, from: data)
        else { return [] }
        return records
    }

    private func saveMetadata(_ records: [Metadata]) {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Keychain helpers

    private func savePassword(_ password: String, for id: UUID) {
        // An anonymous server has no secret to keep. Storing zero bytes is
        // rejected by some Keychain versions and reads back as "" from all of
        // them, so the item is removed instead — same result, no failed write.
        guard !password.isEmpty else {
            deletePassword(for: id)
            return
        }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String:   Data(password.utf8)
        ]
        // Delete first to handle updates (SecItemUpdate not needed for simple upsert)
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func deletePassword(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func loadPassword(for id: UUID) -> String {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  Self.keychainService,
            kSecAttrAccount as String:  id.uuidString,
            kSecReturnData as String:   true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let pw = String(data: data, encoding: .utf8)
        else { return "" }
        return pw
    }
}
