import SwiftUI

// MARK: - ContentView
//
// The app's tab bar. Each tab owns its own NavigationStack so pushing a server
// or a datastream detail does not disturb the others.
//
// Six tabs, three of which are the point. Live is what this device is
// recording; Video, Map and Systems are the same node seen three ways — every
// camera at once, everything positioned at once, everything at all. The old
// Camera tab is the first tile of the video wall and the old Node tab is the
// header of the systems list, because both were a single system's view of a
// question the whole node should answer.
//
// Order runs from what you look at while streaming, through the three shared
// surfaces, to what you look at when something is wrong (Logs) and what you set
// once (Settings).

struct ContentView: View {

    @StateObject private var router = TabRouter()

    var body: some View {
        TabView(selection: $router.selection) {
            LiveTabView()
                .tabItem { Label("Live", systemImage: "waveform.path.ecg") }
                .tag(TabRouter.Tab.live)

            VideoWallView()
                .tabItem { Label("Video", systemImage: "video") }
                .tag(TabRouter.Tab.video)

            MapTabView()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(TabRouter.Tab.map)

            SystemsTabView()
                .tabItem { Label("Systems", systemImage: "square.stack.3d.up") }
                .tag(TabRouter.Tab.systems)

            LogsTabView()
                .tabItem { Label("Logs", systemImage: "text.alignleft") }
                .tag(TabRouter.Tab.logs)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(TabRouter.Tab.settings)
        }
        .environmentObject(router)
    }
}

#Preview {
    ContentView()
        .previewEnvironment()
}
