import SwiftUI

// MARK: - SettingsView
//
// iOS Settings-style screen for system name and server configuration.
// Pushed onto the main NavigationStack via the gear toolbar button.

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettingsStore

    @State private var serverToDelete: ServerConfig?
    @State private var showDeleteAlert = false

    var body: some View {
        Form {
            systemSection
            serversSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .alert("Delete Server", isPresented: $showDeleteAlert, presenting: serverToDelete) { config in
            Button("Delete \"\(config.label)\"", role: .destructive) {
                settings.deleteServer(config)
            }
            Button("Cancel", role: .cancel) {}
        } message: { config in
            Text("This cannot be undone.")
        }
    }

    // MARK: - Sections

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
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environmentObject(AppSettingsStore())
}
