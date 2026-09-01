import SwiftUI

// MARK: - SystemsTabView
//
// Everything on the node, and everything about this device's relationship to
// it, in one list.
//
// This is the old Node tab and the old system browser, which were always the
// same screen split in two: the Node tab answered "which server, does it
// answer, what am I registered as" and then offered a link to a separate screen
// that answered "what is on it". Nobody wants the first without the second.
//
// The header condenses the Node tab — server, connectivity, registration,
// publisher counters while streaming — and the list below it is every system,
// live ones first. This device is the first row, because on a node it is one
// system among the rest and pretending otherwise is what made the old Camera
// and Node tabs feel like a different app from the map.

struct SystemsTabView: View {

    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var connections: NodeConnectionStore
    @EnvironmentObject private var session: SensorSession
    @EnvironmentObject private var activity: ActivityTracker
    @EnvironmentObject private var router: TabRouter

    @StateObject private var model = SystemsModel()

    @State private var search = ""
    @State private var filter: SystemFilter = .all
    @State private var showResetAlert = false

    var body: some View {
        NavigationStack {
            List {
                serverSection
                connectionSection
                registrationSection
                if case .streaming = session.state { publisherSection }
                systemsSection
            }
            .searchable(text: $search, prompt: "Search name or UID")
            .navigationTitle("Systems")
            .toolbar { filterMenu }
            .refreshable { await model.load(connection: connections.active, refresh: true) }
            .task(id: connections.active?.server.id) {
                await model.load(connection: connections.active)
            }
            .alert("Reset cached registration?", isPresented: $showResetAlert) {
                Button("Reset", role: .destructive, action: resetRegistration)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The next session will register this device with \(connections.active?.server.label ?? "the node") again, creating a new system and new datastreams.")
            }
        }
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

            if cachedSystemId != nil {
                NavigationLink {
                    DeviceDatastreamsView(systemId: cachedSystemId ?? "")
                } label: {
                    Label("This device's datastreams", systemImage: "waveform")
                }
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
        Log.client.info("Cleared cached registration for server \(serverId.uuidString, privacy: .public)")
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

    // MARK: Systems

    private var systemsSection: some View {
        Section {
            deviceRow

            ForEach(visibleSystems) { system in
                if let connection = connections.active {
                    NavigationLink {
                        SystemDashboardView(system: system,
                                            connection: connection,
                                            peers: model.systems)
                    } label: {
                        SystemRow(system: system, activity: model.activity(for: system))
                    }
                }
            }

            if model.isLoading && model.systems.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Loading systems…") }
                    .foregroundStyle(.secondary)
            } else if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if visibleSystems.isEmpty && !model.systems.isEmpty {
                Text("No system matches \(filter.label.lowercased()).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if model.systems.isEmpty && !model.isLoading {
                Text("No systems on this node.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Systems")
                Spacer()
                if filter != .all {
                    Text(filter.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// This device, in the same shape as everything else on the node.
    ///
    /// Its detail is the Live tab — this phone's sensors are not a node system
    /// the browser can open, and duplicating the Live tab inside the Systems
    /// tab would be two screens showing one thing.
    private var deviceRow: some View {
        Button {
            router.selection = .live
        } label: {
            deviceRowLabel
        }
        .buttonStyle(.plain)
    }

    private var deviceRowLabel: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "iphone.gen3")
                .font(.title3)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    ActivityDot(state: activity.localDeviceActivity.state)
                    Text("This Device")
                    Spacer()
                }
                Text(registrationSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(session.isActive ? "streaming — open the Live tab"
                                      : "not streaming — open the Live tab to start")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private var registrationSummary: String {
        cachedSystemId ?? "not registered"
    }

    // MARK: Filtering

    private var visibleSystems: [RemoteSystem] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.systems
            .filter { filter.matches($0, activity: model.activity(for: $0)) }
            .filter { system in
                guard !query.isEmpty else { return true }
                return system.name.lowercased().contains(query)
                    || (system.summary.uid ?? "").lowercased().contains(query)
                    || system.id.lowercased().contains(query)
            }
            .sorted { left, right in
                // Live first, then stale, then offline; alphabetical inside
                // each group. A node's listing order is its own business, and
                // "what is talking right now" is what a user came for.
                let leftRank = model.activity(for: left).state.sortRank
                let rightRank = model.activity(for: right).state.sortRank
                if leftRank != rightRank { return leftRank < rightRank }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    private var filterMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Filter", selection: $filter) {
                    ForEach(SystemFilter.allCases) { option in
                        Label(option.label, systemImage: option.symbol).tag(option)
                    }
                }
            } label: {
                Label("Filter", systemImage: filter == .all
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
            }
        }
    }
}

// MARK: - SystemFilter

/// The five questions worth asking of a node's listing.
enum SystemFilter: String, CaseIterable, Identifiable {
    case all
    case live
    case withPosition
    case withVideo
    case withControls

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:           return "All"
        case .live:          return "Live only"
        case .withPosition:  return "With position"
        case .withVideo:     return "With video"
        case .withControls:  return "With controls"
        }
    }

    var symbol: String {
        switch self {
        case .all:           return "square.stack.3d.up"
        case .live:          return "dot.radiowaves.up.forward"
        case .withPosition:  return "mappin.and.ellipse"
        case .withVideo:     return "video"
        case .withControls:  return "slider.horizontal.3"
        }
    }

    /// `.live` takes the activity as an argument rather than looking it up,
    /// because freshness is the one property here that changes while the list
    /// is on screen and the caller already has the answer.
    func matches(_ system: RemoteSystem, activity: SystemActivity) -> Bool {
        switch self {
        case .all:          return true
        case .live:         return activity.state == .live
        case .withPosition: return system.hasPosition
        case .withVideo:    return system.datastreams.contains {
                                    if case .video = $0.role { return true } else { return false }
                                }
        case .withControls: return system.isCommandable
        }
    }
}

// MARK: - SystemRow

struct SystemRow: View {

    let system: RemoteSystem
    let activity: SystemActivity

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: SystemGlyph.symbol(for: system))
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(SystemGlyph.tint(for: system))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    ActivityDot(state: activity.state)
                    Text(system.name)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if let text = ActivityText.relative(activity.lastObservation) {
                        Text(text)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(system.summary.uid ?? system.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                badges
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(system.name), \(ActivityText.accessibility(state: activity.state, lastObservation: activity.lastObservation))")
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 6) {
            badge("\(system.datastreams.count) datastreams", "waveform")
            if !system.subsystems.isEmpty {
                badge("\(system.subsystems.count) subsystems", "square.stack.3d.up")
            }
            if system.controlStreamCount > 0 {
                badge("\(system.controlStreamCount) control", "slider.horizontal.3")
            }
            if system.ptzCapability != nil {
                badge("PTZ", "dpad")
            }
            if system.datastreams.contains(where: { $0.schemaError != nil }) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("some schemas not understood")
            }
        }
    }

    private func badge(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }
}

// MARK: - SystemsModel

/// Every system on the node, loaded whole.
///
/// Eager rather than the lazy per-row loading the old browser used, because
/// sorting by freshness and filtering by "has video" both need the detail
/// before the row is drawn — and a list that reshuffled itself under the user's
/// thumb as details arrived would be worse than a second of spinner. The COP
/// map and the video wall already load a node this way; RemoteSystemLoader's
/// cache means the second and third of them are nearly free.
@MainActor
final class SystemsModel: ObservableObject {

    @Published private(set) var systems: [RemoteSystem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private let loader = RemoteSystemLoader()
    private var connection: NodeConnection?

    func load(connection: NodeConnection?, refresh: Bool = false) async {
        self.connection = connection
        guard let connection else {
            systems = []
            error = "Select a server to browse its systems."
            return
        }

        isLoading = true
        defer { isLoading = false }

        if refresh { await loader.invalidate(serverId: connection.server.id) }

        do {
            let summaries = try await connection.readClient.listSystems(limit: 200)
            systems = await loader.loadAll(summaries,
                                           using: connection.readClient,
                                           serverId: connection.server.id,
                                           refresh: refresh)
            for system in systems {
                ActivityTracker.shared.seed(system.activity,
                                            serverId: connection.server.id,
                                            systemId: system.id)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            Log.client.error("System listing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func activity(for system: RemoteSystem) -> SystemActivity {
        guard let serverId = connection?.server.id else { return system.activity }
        return ActivityTracker.shared.activity(serverId: serverId, systemId: system.id)
    }
}
