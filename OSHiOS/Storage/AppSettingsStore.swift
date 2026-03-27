import Foundation
import UIKit

// MARK: - AppSettingsStore
//
// ObservableObject that owns all persisted app-level settings.
// Inject as @EnvironmentObject from osh_iosApp.

final class AppSettingsStore: ObservableObject {

    // MARK: - System name

    /// Human-readable name shown on the OSH node. Defaults to the device name.
    @Published var systemName: String {
        didSet { UserDefaults.standard.set(systemName, forKey: "osh.systemName") }
    }

    // MARK: - Server configs

    @Published var serverConfigs: [ServerConfig] = []

    /// ID of the currently selected server.
    @Published var activeServerId: UUID? {
        didSet {
            UserDefaults.standard.set(activeServerId?.uuidString,
                                      forKey: "osh.activeServerId")
        }
    }

    /// The currently selected ServerConfig, or nil if none is selected.
    var activeServer: ServerConfig? {
        serverConfigs.first { $0.id == activeServerId }
    }

    // MARK: - Private

    private let store = KeychainServerStore()

    // MARK: - Init

    init() {
        self.systemName = UserDefaults.standard.string(forKey: "osh.systemName")
            ?? UIDevice.current.name
        self.serverConfigs = store.loadAll()
        if let idString = UserDefaults.standard.string(forKey: "osh.activeServerId"),
           let id = UUID(uuidString: idString) {
            self.activeServerId = id
        }
    }

    // MARK: - Server management

    func saveServer(_ config: ServerConfig) {
        try? store.save(config)
        serverConfigs = store.loadAll()
        // Auto-select the first server added
        if activeServerId == nil {
            activeServerId = config.id
        }
    }

    func deleteServer(_ config: ServerConfig) {
        try? store.delete(config)
        serverConfigs = store.loadAll()
        if activeServerId == config.id {
            activeServerId = serverConfigs.first?.id
        }
    }
}
