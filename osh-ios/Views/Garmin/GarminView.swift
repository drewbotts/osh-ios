import SwiftUI

// MARK: - GarminView
//
// Form-based UI for Garmin Connect IQ SDK integration.
// Sections: license entry, device status/scanning, streaming config, data toggles.

struct GarminView: View {
    @EnvironmentObject private var garminSettings: GarminSettingsStore
    @EnvironmentObject private var garmin: GarminManager

    // MARK: - Local state

    @State private var licenseEntry: String = ""
    @State private var showLicenseClear = false

    // MARK: - Body

    var body: some View {
        Form {
            licenseSection
            if garmin.deviceState != .sdkUnavailable {
                deviceSection
                streamingSection
                dataTypesSection
            }
        }
        .navigationTitle("Garmin")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            licenseEntry = garminSettings.licenseKey
        }
    }

    // MARK: - License section

    private var licenseSection: some View {
        Section {
            if garminSettings.licenseKey.isEmpty {
                // Entry mode — SDK not activated
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("Paste Connect IQ license key", text: $licenseEntry)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Activate") {
                        let key = licenseEntry.trimmingCharacters(in: .whitespaces)
                        guard !key.isEmpty else { return }
                        garminSettings.saveLicenseKey(key)
                        garmin.start(licenseKey: key)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(licenseEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.vertical, 4)
            } else {
                // Key stored — show masked representation
                LabeledContent("License Key") {
                    Text("••••••••")
                        .foregroundStyle(.secondary)
                }
                Button("Remove License Key", role: .destructive) {
                    showLicenseClear = true
                }
                .confirmationDialog(
                    "Remove the Garmin license key?",
                    isPresented: $showLicenseClear,
                    titleVisibility: .visible
                ) {
                    Button("Remove", role: .destructive) {
                        garminSettings.clearLicenseKey()
                        garmin.stop()
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
        } header: {
            Text("SDK License")
        } footer: {
            if garminSettings.licenseKey.isEmpty {
                Text("A Garmin Connect IQ SDK license key is required to enable wearable integration.")
                    .font(.footnote)
            }
        }
    }

    // MARK: - Device section

    private var deviceSection: some View {
        Section("Device") {
            LabeledContent("Status", value: deviceStateLabel)
                .foregroundStyle(deviceStateColor)

            if let name = garmin.pairedDeviceName {
                LabeledContent("Connected", value: name)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            switch garmin.deviceState {
            case .ready:
                Button("Scan for Devices") {
                    garmin.startScan()
                }

            case .scanning:
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Scanning…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { garmin.stopScan() }
                        .foregroundStyle(.red)
                }

            case .connected:
                Button("Sync Now") {
                    garmin.syncNow()
                }

                Button("Disconnect", role: .destructive) {
                    garmin.disconnect()
                }

            case .syncing(let device):
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Syncing \(device)…").foregroundStyle(.secondary)
                }

            case .error(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)

            default:
                EmptyView()
            }
        }
    }

    // MARK: - Streaming section

    private var streamingSection: some View {
        Section("Streaming") {
            Picker("Mode", selection: $garminSettings.settings.streamingMode) {
                Text("Real-Time").tag(GarminStreamingMode.realTime)
                Text("Interval Sync").tag(GarminStreamingMode.interval)
            }
            .pickerStyle(.segmented)
            .onChange(of: garminSettings.settings.streamingMode) { _, _ in
                garminSettings.saveSettings()
            }

            if garminSettings.settings.streamingMode == .interval {
                Picker("Sync Interval", selection: $garminSettings.settings.syncIntervalMinutes) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
                .onChange(of: garminSettings.settings.syncIntervalMinutes) { _, _ in
                    garminSettings.saveSettings()
                }
            }
        }
    }

    // MARK: - Data types section

    private var dataTypesSection: some View {
        Section("Data Types") {
            Toggle("Heart Rate", isOn: $garminSettings.settings.enableHeartRate)
                .onChange(of: garminSettings.settings.enableHeartRate) { _, _ in
                    garminSettings.saveSettings()
                }
            Toggle("Stress", isOn: $garminSettings.settings.enableStress)
                .onChange(of: garminSettings.settings.enableStress) { _, _ in
                    garminSettings.saveSettings()
                }
            Toggle("Respiration", isOn: $garminSettings.settings.enableRespiration)
                .onChange(of: garminSettings.settings.enableRespiration) { _, _ in
                    garminSettings.saveSettings()
                }
            Toggle("Accelerometer", isOn: $garminSettings.settings.enableAccelerometer)
                .onChange(of: garminSettings.settings.enableAccelerometer) { _, _ in
                    garminSettings.saveSettings()
                }

            Text("Changes apply on next session start.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var deviceStateLabel: String {
        switch garmin.deviceState {
        case .sdkUnavailable:      return "SDK unavailable"
        case .notInitialized:      return "Not initialized"
        case .initializing:        return "Initializing…"
        case .ready:               return "Ready"
        case .scanning:            return "Scanning…"
        case .connecting(let d):   return "Connecting to \(d)…"
        case .connected(let d):    return "Connected to \(d)"
        case .syncing(let d):      return "Syncing \(d)…"
        case .error(let m):        return "Error: \(m)"
        }
    }

    private var deviceStateColor: Color {
        switch garmin.deviceState {
        case .sdkUnavailable, .notInitialized: return .secondary
        case .initializing, .scanning, .connecting, .syncing: return .orange
        case .ready:                           return .secondary
        case .connected:                       return .green
        case .error:                           return .red
        }
    }
}

#Preview {
    NavigationStack {
        GarminView()
            .environmentObject(GarminSettingsStore())
            .environmentObject(GarminManager.shared)
    }
}
