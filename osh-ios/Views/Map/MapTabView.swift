import SwiftUI

// MARK: - MapTabView
//
// The adapter between SensorSession and TrackMapView. Everything session-shaped
// stops here: the map itself takes plain track points, so pointing it at a
// remote system later means changing this file and nothing below it.

struct MapTabView: View {

    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var session: SensorSession

    @State private var isFollowing = true

    var body: some View {
        NavigationStack {
            Group {
                if !settings.config.enableGPS {
                    ContentUnavailableView {
                        Label("GPS is off", systemImage: "location.slash")
                    } description: {
                        Text("Enable GPS in Settings to record a track.")
                    }
                } else if session.currentFix == nil {
                    ContentUnavailableView {
                        Label("No fix yet", systemImage: "location.magnifyingglass")
                    } description: {
                        Text(waitingDescription)
                    }
                } else {
                    TrackMapView(track: session.gpsTrack,
                                 currentFix: session.currentFix,
                                 isFollowing: $isFollowing,
                                 onClearTrack: session.clearTrack)
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var waitingDescription: String {
        if case .streaming = session.state {
            return "Waiting for the first GPS fix. Outdoors is quicker."
        }
        return "Start a session on the Live tab to record a track."
    }
}

#Preview {
    MapTabView()
        .previewEnvironment()
}
