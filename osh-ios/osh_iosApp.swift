import SwiftUI

@main
struct osh_iosApp: App {
    @StateObject private var settings = AppSettingsStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
        }
    }
}
