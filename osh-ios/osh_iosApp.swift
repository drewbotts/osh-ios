import SwiftUI

@main
struct osh_iosApp: App {
    @StateObject private var settings = AppSettingsStore()
    @StateObject private var nav = AppNavigationState()
    @StateObject private var garminSettings = GarminSettingsStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(nav)
                .environmentObject(garminSettings)
                .environmentObject(GarminManager.shared)
                .onAppear {
                    // Auto-start Garmin SDK if a license key was previously saved.
                    // Done in onAppear (not App.init) so we use the single @StateObject instance.
                    if !garminSettings.licenseKey.isEmpty {
                        GarminManager.shared.start(licenseKey: garminSettings.licenseKey)
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.willEnterForegroundNotification)
                ) { _ in
                    triggerIntervalSyncIfNeeded()
                }
        }
    }

    @MainActor
    private func triggerIntervalSyncIfNeeded() {
        guard garminSettings.settings.streamingMode == .interval else { return }
        let garmin = GarminManager.shared
        guard case .connected = garmin.deviceState else { return }
        garmin.syncNow()
    }
}
