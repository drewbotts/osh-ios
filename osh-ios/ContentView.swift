import SwiftUI

struct ContentView: View {
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
                if isStreaming {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Stop", role: .destructive) { session.stop() }
                            .tint(.red)
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section("Server") {
            TextField("OSH Node URL", text: $config.nodeURL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            TextField("Username", text: $config.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("Password", text: $config.password)
        }
        .disabled(isStreaming)
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
        .disabled(isStreaming)
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Session", value: stateLabel)
                .foregroundStyle(stateColor)

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
            Button(isStreaming ? "Stop" : "Start") {
                if isStreaming {
                    session.stop()
                } else {
                    config.save()
                    session.start(config: config)
                }
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(isStreaming ? .red : .green)

            if case .error(let msg) = session.state {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button("Reset cached registration") {
                    SystemRegistration.clearCachedId()
                    DatastreamRegistration.clearCachedIds()
                }
                .font(.footnote)
            }
        }
    }

    // MARK: - Helpers

    private var isStreaming: Bool {
        switch session.state {
        case .registering, .streaming: return true
        default: return false
        }
    }

    private var stateLabel: String {
        switch session.state {
        case .idle:                return "Idle"
        case .registering(let m):  return m
        case .streaming:           return "Streaming"
        case .error(let e):        return "Error"
        }
    }

    private var stateColor: Color {
        switch session.state {
        case .idle:        return .secondary
        case .registering: return .orange
        case .streaming:   return .green
        case .error:       return .red
        }
    }
}

#Preview {
    ContentView()
}
