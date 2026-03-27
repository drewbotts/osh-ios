import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var config = AppConfig.load()
    @StateObject private var session = SensorSession()

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                sensorsSection
                statusSection
                actionSection
            }
            .navigationTitle("OSH Sensor Hub")
            .onDisappear { session.stop() }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gear")
                    }
                    .disabled(session.isActive)
                }
            }
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section("Server") {
            if settings.serverConfigs.isEmpty {
                Text("No server configured — go to Settings to add one.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            } else {
                Picker("Server", selection: $settings.activeServerId) {
                    Text("None selected").tag(nil as UUID?)
                    ForEach(settings.serverConfigs) { server in
                        Text(server.label).tag(server.id as UUID?)
                    }
                }
                .pickerStyle(.menu)

                if let server = settings.activeServer {
                    Text(server.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .disabled(session.isActive)
    }

    private var sensorsSection: some View {
        Section("Sensors") {
            Toggle("GPS",                   isOn: $config.enableGPS)
            Toggle("Orientation (Quat)",    isOn: $config.enableOrientationQuat)
            Toggle("Orientation (Euler)",   isOn: $config.enableOrientationEuler)
            Toggle("Barometer",             isOn: $config.enableBarometer)
            Toggle("Audio Level",           isOn: $config.enableAudioLevel)
            Toggle("Video H264",            isOn: $config.enableVideoH264)
            if config.enableVideoH264 {
                Picker("Frame Rate", selection: $config.videoConfig.frameRate) {
                    ForEach([1, 2, 5, 10, 15, 25], id: \.self) { fps in
                        Text("\(fps) fps").tag(fps)
                    }
                }
            }
        }
        .disabled(session.isActive)
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Session", value: stateLabel)
                .foregroundStyle(stateColor)

            // Mid-session network loss indicator — observations are buffering locally.
            // ObservationPublisher's ring buffer will drain once connectivity returns.
            if case .streaming = session.state, !session.isNetworkConnected {
                LabeledContent("Network", value: "Unavailable — buffering")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if !session.sensorStatus.isEmpty {
                ForEach(session.sensorStatus.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    let unavailable = value.hasPrefix("Unavailable:")
                    LabeledContent(key, value: value)
                        .font(.footnote)
                        .foregroundStyle(unavailable ? Color.red.opacity(0.7) : .secondary)
                }
            }
        }
    }

    private var actionSection: some View {
        Section {
            switch session.state {

            case .idle:
                Button("Start Streaming") {
                    config.save()
                    if let server = settings.activeServer {
                        session.start(config: config,
                                      server: server,
                                      systemName: settings.systemName)
                    }
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.borderedProminent)
                .disabled(settings.activeServer == nil)

            case .connecting(let step):
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text(step).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    Button("Cancel") { session.cancelStartup() }
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.red)
                }
                .padding(.vertical, 4)

            case .streaming:
                Button("Stop Streaming") { session.stop() }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.red)

            case .failed(let error):
                let msg = SensorSession.userFacingMessage(for: error)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(msg.title)
                                .foregroundStyle(.red)
                                .font(.footnote.weight(.semibold))
                            Text(msg.suggestion)
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        }
                    }
                    HStack(spacing: 16) {
                        Button("Retry") {
                            config.save()
                            if let server = settings.activeServer {
                                session.start(config: config,
                                              server: server,
                                              systemName: settings.systemName)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(settings.activeServer == nil)

                        Button("Dismiss") { session.dismissError() }
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // Debug helper — only shown after a failed startup
            if case .failed = session.state {
                Button("Reset cached registration") {
                    SystemRegistration.clearCachedId()
                    DatastreamRegistration.clearCachedIds()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private var stateLabel: String {
        switch session.state {
        case .idle:               return "Idle"
        case .connecting(let m):  return m
        case .streaming:          return "Streaming"
        case .failed:             return "Failed"
        }
    }

    private var stateColor: Color {
        switch session.state {
        case .idle:        return .secondary
        case .connecting:  return .orange
        case .streaming:   return .green
        case .failed:      return .red
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppSettingsStore())
}
