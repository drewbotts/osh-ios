import SwiftUI

// MARK: - MapTabView
//
// Two maps behind one segmented control: what this device is recording, and
// what the node knows.
//
// The device half is exactly what it was — SensorSession in, TrackMapView out —
// and none of the node code can reach it. That separation is deliberate: the
// track this phone is recording has to keep working whether or not a node is
// configured, reachable or interesting.

struct MapTabView: View {

    enum Source: String, CaseIterable, Identifiable {
        case device = "This Device"
        case node = "Node"
        var id: String { rawValue }
    }

    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var session: SensorSession
    @EnvironmentObject private var connections: NodeConnectionStore

    @State private var source: Source = .device
    @State private var isFollowing = true

    var body: some View {
        NavigationStack {
            Group {
                switch source {
                case .device: deviceMap
                case .node:   NodeMapView()
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Source", selection: $source) {
                        ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }
            }
        }
    }

    // MARK: This device

    @ViewBuilder
    private var deviceMap: some View {
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
