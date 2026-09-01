import SwiftUI

@main
struct osh_iosApp: App {

    // One instance of each of these exists for the life of the app. In
    // particular there is exactly one SensorSession: it owns live hardware, so
    // a second one created by a view would start a second camera and a second
    // motion manager behind the first one's back.
    @StateObject private var settings    = AppSettingsStore()
    @StateObject private var connections = NodeConnectionStore()
    @StateObject private var session     = SensorSession()
    @StateObject private var activity    = ActivityTracker.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(connections)
                .environmentObject(session)
                .environmentObject(activity)
                // The decay timer is what turns a green dot amber when a system
                // simply stops talking; nothing else would ever redraw it.
                .task { activity.start() }
                // This device is live by definition while its own session runs.
                .onChange(of: session.isActive) { _, isActive in
                    activity.isLocalDeviceStreaming = isActive
                }
                // Keep the node connection in step with the selected server.
                // @Published fires on willSet, so the *new* value is taken from
                // the closure argument rather than re-read from the store.
                .onReceive(settings.$activeServerId) { activeId in
                    connections.select(server: settings.serverConfigs.first { $0.id == activeId })
                }
                .onReceive(settings.$serverConfigs) { configs in
                    connections.select(server: configs.first { $0.id == settings.activeServerId })
                }
                .task { await autoStartIfRequested() }
        }
    }

    /// Starts a session shortly after launch when the user has asked for it.
    ///
    /// The delay is what makes this work at all: the connection is built from
    /// the onReceive wiring above, which has not run when this task first
    /// fires, and CoreLocation and the camera want the app to be foreground and
    /// settled before they are asked for anything.
    private func autoStartIfRequested() async {
        guard settings.config.autoStartOnLaunch else { return }
        try? await Task.sleep(for: .seconds(1))
        guard let connection = connections.active else {
            Log.session.info("Auto-start requested but no server is selected")
            return
        }
        Log.session.info("Auto-starting session on launch")
        session.start(config: settings.config,
                      connection: connection,
                      systemName: settings.systemName)
    }
}
