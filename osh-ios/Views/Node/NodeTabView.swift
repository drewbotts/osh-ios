import SwiftUI

// MARK: - NodeTabView
//
// Everything about the OSH node this device talks to: which one, whether it
// answers, what this device is registered as, and what datastreams exist under
// that registration. The datastream and system listings are the first read-side
// features in the app and the seed of the viewer that follows.

struct NodeTabView: View {

    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var connections: NodeConnectionStore
    @EnvironmentObject private var session: SensorSession

    @State private var datastreams: [DatastreamSummary] = []
    @State private var datastreamError: String?
    @State private var isLoadingDatastreams = false

    @State private var systems: [SystemSummary] = []
    @State private var systemsError: String?
    @State private var isLoadingSystems = false
    @State private var showSystems = false

    @State private var showResetAlert = false

    var body: some View {
        NavigationStack {
            List {
                serverSection
                connectionSection
                registrationSection
                datastreamsSection
                if case .streaming = session.state { publisherSection }
                systemsSection
            }
            .navigationTitle("Node")
            .refreshable { await loadDatastreams() }
            .task(id: refreshKey) { await loadDatastreams() }
            .alert("Reset cached registration?", isPresented: $showResetAlert) {
                Button("Reset", role: .destructive, action: resetRegistration)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The next session will register this device with \(connections.active?.server.label ?? "the node") again, creating a new system and new datastreams.")
            }
        }
    }

    /// Reloads when either the server or the cached registration changes.
    private var refreshKey: String {
        "\(connections.active?.server.id.uuidString ?? "none")|\(cachedSystemId ?? "none")"
    }

    // MARK: Server

    private var serverSection: some View {
        Section("Server") {
            if settings.serverConfigs.isEmpty {
                Text("No servers configured. Add one in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Server", selection: $settings.activeServerId) {
                    Text("None selected").tag(nil as UUID?)
                    ForEach(settings.serverConfigs) { server in
                        Text(server.label).tag(server.id as UUID?)
                    }
                }
                .disabled(session.isActive)

                if let server = connections.active?.server {
                    LabeledContent("URL") {
                        Text(server.url)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                if let error = connections.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: Connectivity

    @ViewBuilder
    private var connectionSection: some View {
        if let connection = connections.active {
            Section("Connection") {
                Button {
                    Task { await connection.checkConnectivity() }
                } label: {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if connection.isChecking { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(connection.isChecking)

                if let result = connection.reachability {
                    reachabilityRow(result, checkedAt: connection.lastCheckedAt)
                }
            }
        }
    }

    private func reachabilityRow(_ result: ConnectivityResult, checkedAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch result {
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .authenticationFailed:
                Label("Authentication failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .unreachable(let message):
                Label("Unreachable", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let checkedAt {
                Text("Checked \(checkedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    // MARK: Registration

    private var cachedSystemId: String? {
        connections.active.map { SystemRegistration.cachedId(serverId: $0.server.id) } ?? nil
    }

    private var registrationSection: some View {
        Section {
            LabeledContent("System ID") {
                Text(cachedSystemId ?? "not registered")
                    .foregroundStyle(cachedSystemId == nil ? .secondary : .primary)
                    .textSelection(.enabled)
            }

            Button("Reset cached registration", role: .destructive) {
                showResetAlert = true
            }
            .disabled(connections.active == nil || session.isActive)
        } header: {
            Text("Registration")
        } footer: {
            Text("Registration ids are cached per server, because each node mints its own.")
        }
    }

    private func resetRegistration() {
        guard let serverId = connections.active?.server.id else { return }
        SystemRegistration.clearCachedId(serverId: serverId)
        DatastreamRegistration.clearCachedIds(serverId: serverId)
        datastreams = []
        Log.client.info("Cleared cached registration for server \(serverId.uuidString, privacy: .public)")
    }

    // MARK: Datastreams

    @ViewBuilder
    private var datastreamsSection: some View {
        Section("Datastreams") {
            if connections.active == nil {
                Text("Select a server to browse its datastreams.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if cachedSystemId == nil {
                Text("This device is not registered yet. Start a session to create its system and datastreams.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if isLoadingDatastreams && datastreams.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Loading…") }
                    .foregroundStyle(.secondary)
            } else if let datastreamError {
                Label(datastreamError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if datastreams.isEmpty {
                Text("No datastreams on this system.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(datastreams) { datastream in
                    NavigationLink {
                        DatastreamDetailView(datastream: datastream)
                    } label: {
                        DatastreamRow(datastream: datastream, stats: localStats(for: datastream))
                    }
                }
            }
        }
    }

    /// Live counters, but only for a datastream this session is actually
    /// feeding — a stream from an earlier run has no numbers to show.
    private func localStats(for datastream: DatastreamSummary) -> StreamStats? {
        guard case .streaming = session.state else { return nil }
        let name = datastream.outputName ?? datastream.name
        return session.sensors[name]?.stats
    }

    private func loadDatastreams() async {
        guard let connection = connections.active, let systemId = cachedSystemId else {
            datastreams = []
            datastreamError = nil
            return
        }
        isLoadingDatastreams = true
        defer { isLoadingDatastreams = false }
        do {
            datastreams = try await connection.readClient.listDatastreams(systemId: systemId)
            datastreamError = nil
        } catch {
            datastreamError = error.localizedDescription
            Log.client.error("Datastream listing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Publisher

    private var publisherSection: some View {
        Section("Publisher") {
            LabeledContent("Status",
                           value: session.isNetworkConnected ? "Connected" : "Disconnected")
                .foregroundStyle(session.isNetworkConnected ? .primary : Color.orange)
            LabeledContent("Queued", value: "\(session.queuedCount)")
            LabeledContent("Sent", value: "\(session.sentCount)")
            LabeledContent("Errors", value: "\(session.errorCount)")
                .foregroundStyle(session.errorCount > 0 ? Color.orange : .primary)
        }
        .monospacedDigit()
    }

    // MARK: Systems browser

    private var systemsSection: some View {
        Section {
            DisclosureGroup("Browse systems on node", isExpanded: $showSystems) {
                if isLoadingSystems {
                    HStack { ProgressView().controlSize(.small); Text("Loading…") }
                        .foregroundStyle(.secondary)
                } else if let systemsError {
                    Label(systemsError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if systems.isEmpty {
                    Text("No systems returned.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(systems) { system in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(system.name)
                            Text(system.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onChange(of: showSystems) { _, expanded in
                guard expanded else { return }
                Task { await loadSystems() }
            }
        } header: {
            Text("Systems")
        } footer: {
            Text("Read-only for now. A later pass turns this into a full system browser.")
        }
    }

    private func loadSystems() async {
        guard let connection = connections.active else { return }
        isLoadingSystems = true
        defer { isLoadingSystems = false }
        do {
            systems = try await connection.readClient.listSystems()
            systemsError = nil
        } catch {
            systemsError = error.localizedDescription
            Log.client.error("System listing failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - DatastreamRow

struct DatastreamRow: View {

    let datastream: DatastreamSummary
    let stats: StreamStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(datastream.name)
            Text(datastream.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let formats = datastream.formats, !formats.isEmpty {
                Text(formats.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let stats {
                Text(statsText(stats))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(stats.errors > 0 ? Color.orange : .secondary)
            }
        }
    }

    private func statsText(_ stats: StreamStats) -> String {
        "sent \(stats.observations) · \(formattedBytes(stats.bytes)) · errors \(stats.errors)"
    }

    private func formattedBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}

#Preview {
    NodeTabView()
        .previewEnvironment()
}

#Preview("Datastream row") {
    List {
        DatastreamRow(datastream: PreviewSupport.datastreams[0],
                      stats: StreamStats(observations: 412, bytes: 39_552, errors: 0, rate: 1))
        DatastreamRow(datastream: PreviewSupport.datastreams[1], stats: nil)
    }
}
