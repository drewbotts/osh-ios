import SwiftUI

// MARK: - LiveTabView
//
// Session control plus one card per enabled sensor. Cards appear in the order
// the session builds its modules, and only for sensors that are switched on —
// a greyed-out card for a disabled sensor would say nothing the Settings tab
// does not already say.

struct LiveTabView: View {

    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var session: SensorSession

    private let columns = [GridItem(.adaptive(minimum: 165), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    SessionBar()

                    if session.sensorList.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(session.sensorList) { sensor in
                                SensorCard(sensor: sensor,
                                           videoStats: session.videoStats)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Live")
        }
    }

    // MARK: Empty state

    @ViewBuilder
    private var emptyState: some View {
        if enabledSensorCount == 0 {
            ContentUnavailableView {
                Label("No sensors enabled", systemImage: "sensor.tag.radiowaves.forward")
            } description: {
                Text("Turn on the sensors you want to stream in Settings.")
            }
            .frame(maxWidth: .infinity)
        } else {
            ContentUnavailableView {
                Label("Not streaming", systemImage: "waveform.path.ecg")
            } description: {
                Text("\(enabledSensorCount) sensor\(enabledSensorCount == 1 ? "" : "s") ready. Start a session to see live readings.")
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Mirrors the enables SensorSession consults when it builds modules.
    private var enabledSensorCount: Int {
        let config = settings.config
        return [config.enableGPS,
                config.enableOrientationQuat,
                config.enableOrientationEuler,
                config.enableBarometer,
                config.enableAudioLevel,
                config.enableVideoH264].filter { $0 }.count
    }
}

#Preview {
    LiveTabView()
        .previewEnvironment()
}
