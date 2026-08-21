import SwiftUI

// MARK: - SettingsView
//
// Everything that is configured rather than observed: which system name this
// device publishes under, which servers it knows about, which sensors are on,
// how fast they sample, and what happens at launch.
//
// Sensor settings are disabled while a session is active. They are read once,
// when the session builds its modules and registers its datastreams, so a
// change mid-run would apply to nothing while appearing to have taken effect.

struct SettingsView: View {

    @EnvironmentObject var settings: AppSettingsStore
    @EnvironmentObject private var session: SensorSession

    @State private var serverToDelete: ServerConfig?
    @State private var showDeleteAlert = false

    /// Selectable orientation update intervals, in seconds.
    private static let orientationIntervals: [Double] = [0.05, 0.1, 0.2, 0.5, 1.0]
    /// Selectable audio level intervals, in seconds.
    private static let audioIntervals: [Double] = [0.1, 0.25, 0.5, 1.0]

    private static let repositoryURL = URL(string: "https://github.com/opensensorhub/osh-ios")!

    var body: some View {
        NavigationStack {
            Form {
                systemSection
                serversSection
                sensorsSection
                sampleRatesSection
                behaviorSection
                aboutSection
            }
            .navigationTitle("Settings")
            .alert("Delete Server", isPresented: $showDeleteAlert, presenting: serverToDelete) { config in
                Button("Delete \"\(config.label)\"", role: .destructive) {
                    settings.deleteServer(config)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This cannot be undone.")
            }
        }
    }

    // MARK: - System

    private var systemSection: some View {
        Section {
            TextField("System Name", text: $settings.systemName)
                .autocorrectionDisabled()
            Text("This name appears on your OSH node. Changes apply on next session start.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("System")
        }
    }

    // MARK: - Servers

    private var serversSection: some View {
        Section {
            if settings.serverConfigs.isEmpty {
                Text("No servers configured. Tap + to add one.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            } else {
                ForEach(settings.serverConfigs) { config in
                    NavigationLink(destination: ServerDetailView(existingConfig: config)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(config.label)
                            Text(config.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) {
                            serverToDelete = config
                            showDeleteAlert = true
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Servers")
                Spacer()
                NavigationLink(destination: ServerDetailView()) {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                }
            }
        }
    }

    // MARK: - Sensors

    private var sensorsSection: some View {
        Section {
            Toggle("GPS",                 isOn: $settings.config.enableGPS)
            Toggle("Orientation (Quat)",  isOn: $settings.config.enableOrientationQuat)
            Toggle("Orientation (Euler)", isOn: $settings.config.enableOrientationEuler)
            Toggle("Barometer",           isOn: $settings.config.enableBarometer)
            Toggle("Audio Level",         isOn: $settings.config.enableAudioLevel)
            Toggle("Video H264",          isOn: $settings.config.enableVideoH264)
        } header: {
            Text("Sensors")
        } footer: {
            if session.isActive {
                Text("Stop streaming to change which sensors run.")
            }
        }
        .disabled(session.isActive)
    }

    // MARK: - Sample rates

    private var sampleRatesSection: some View {
        Section {
            Picker("Orientation", selection: $settings.config.orientationInterval) {
                ForEach(Self.orientationIntervals, id: \.self) { interval in
                    Text(Self.intervalLabel(interval)).tag(interval)
                }
            }
            Picker("Audio Level", selection: $settings.config.audioInterval) {
                ForEach(Self.audioIntervals, id: \.self) { interval in
                    Text(Self.intervalLabel(interval)).tag(interval)
                }
            }
        } header: {
            Text("Sample Rates")
        } footer: {
            Text("Faster sampling means more observations per second on the node. GPS and barometer are driven by the hardware and cannot be set here.")
        }
        .disabled(session.isActive)
    }

    /// Shows both the period and the rate — the period is what is stored, the
    /// rate is what people think in.
    private static func intervalLabel(_ interval: Double) -> String {
        let hz = 1.0 / interval
        let hzText = hz >= 10 ? String(format: "%.0f", hz) : String(format: "%.4g", hz)
        return "\(String(format: "%g", interval)) s (\(hzText) Hz)"
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        Section {
            Toggle("Auto-start on launch", isOn: $settings.config.autoStartOnLaunch)
        } header: {
            Text("Behavior")
        } footer: {
            Text("Begins streaming a second after launch, if a server is selected.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Self.versionString)
            Link(destination: Self.repositoryURL) {
                Label("GitHub repository", systemImage: "link")
            }
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
        .previewEnvironment()
}
