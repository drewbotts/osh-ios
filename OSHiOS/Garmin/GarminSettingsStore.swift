import Foundation
import Security

// MARK: - GarminStreamingMode

enum GarminStreamingMode: String, Codable, CaseIterable {
    case realTime  = "realTime"   // push observations live while streaming
    case interval  = "interval"   // periodic FIT file sync only
}

// MARK: - GarminSettings
//
// All non-sensitive settings are persisted in UserDefaults.
// The Garmin Connect IQ license key is stored in Keychain under
// service "osh.ios", account "garmin.license".

struct GarminSettings: Codable {
    var streamingMode: GarminStreamingMode = .realTime
    var syncIntervalMinutes: Int           = 15
    var enableHeartRate: Bool              = true
    var enableStress: Bool                 = true
    var enableRespiration: Bool            = true
    var enableAccelerometer: Bool          = false
}

// MARK: - GarminSettingsStore

final class GarminSettingsStore: ObservableObject {

    // MARK: - Published properties

    @Published var settings: GarminSettings = GarminSettings() {
        didSet { saveSettings() }
    }

    /// The Garmin Connect IQ SDK license key — stored in Keychain, not UserDefaults.
    /// Empty string means no key is configured.
    @Published var licenseKey: String = ""

    // MARK: - Keys

    private static let defaultsKey     = "osh.garminSettings"
    private static let keychainService = "osh.ios"
    private static let keychainAccount = "garmin.license"

    // MARK: - Init

    init() {
        settings   = loadSettings()
        licenseKey = loadLicenseKey()
    }

    // MARK: - Public API

    func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    func saveLicenseKey(_ key: String) {
        licenseKey = key
        storeLicenseKey(key)
    }

    func clearLicenseKey() {
        licenseKey = ""
        deleteLicenseKey()
    }

    // MARK: - UserDefaults helpers

    private func loadSettings() -> GarminSettings {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode(GarminSettings.self, from: data)
        else { return GarminSettings() }
        return decoded
    }

    // MARK: - Keychain helpers

    private func loadLicenseKey() -> String {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  Self.keychainService,
            kSecAttrAccount as String:  Self.keychainAccount,
            kSecReturnData as String:   true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return "" }
        return key
    }

    private func storeLicenseKey(_ key: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      Self.keychainService,
            kSecAttrAccount as String:      Self.keychainAccount,
            kSecValueData as String:        Data(key.utf8),
            kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func deleteLicenseKey() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
