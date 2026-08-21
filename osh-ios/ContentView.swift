import SwiftUI

// MARK: - ContentView
//
// The app's tab bar. Each tab owns its own NavigationStack so pushing a server
// or a datastream detail does not disturb the others.
//
// Order runs from what you look at while streaming (Live, Camera, Map) to what
// you look at when something is wrong (Node, Logs) to what you set once
// (Settings).

struct ContentView: View {

    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var connections: NodeConnectionStore
    @EnvironmentObject private var session: SensorSession

    var body: some View {
        TabView {
            LiveTabView()
                .tabItem { Label("Live", systemImage: "waveform.path.ecg") }

            CameraTabView()
                .tabItem { Label("Camera", systemImage: "video") }

            MapTabView()
                .tabItem { Label("Map", systemImage: "map") }

            NodeTabView()
                .tabItem { Label("Node", systemImage: "server.rack") }

            LogsTabView()
                .tabItem { Label("Logs", systemImage: "text.alignleft") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}

#Preview {
    ContentView()
        .previewEnvironment()
}
