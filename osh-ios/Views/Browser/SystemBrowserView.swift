import SwiftUI

// MARK: - SystemBrowserView
//
// Every system on the node, with enough of each loaded to be worth tapping.
//
// The badges — datastreams, subsystems, control streams — need a
// RemoteSystemLoader round trip each, so they load when a row scrolls into
// view rather than up front: a node with forty systems would otherwise fetch
// several hundred schemas before drawing anything. Placeholders hold the row's
// height so the list does not jump as they arrive.

struct SystemBrowserView: View {

    @EnvironmentObject private var connections: NodeConnectionStore

    @StateObject private var model = SystemBrowserModel()
    @State private var search = ""

    var body: some View {
        List {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            ForEach(filtered) { summary in
                row(summary)
            }

            if model.isLoading && model.systems.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Loading systems…") }
                    .foregroundStyle(.secondary)
            } else if !model.isLoading && model.systems.isEmpty && model.error == nil {
                Text("No systems on this node.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .searchable(text: $search, prompt: "Search name or UID")
        .navigationTitle("Browse node")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load(connection: connections.active, refresh: true) }
        .task(id: connections.active?.server.id) {
            await model.load(connection: connections.active)
        }
    }

    private var filtered: [SystemSummary] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.systems }
        return model.systems.filter {
            $0.name.lowercased().contains(query)
                || ($0.uid ?? "").lowercased().contains(query)
                || $0.id.lowercased().contains(query)
        }
    }

    // MARK: Row

    @ViewBuilder
    private func row(_ summary: SystemSummary) -> some View {
        let loaded = model.loaded[summary.id]

        if let loaded, let connection = connections.active {
            NavigationLink {
                SystemDashboardView(system: loaded, connection: connection)
            } label: {
                SystemRow(summary: summary, system: loaded)
            }
        } else {
            SystemRow(summary: summary, system: nil)
                .task { await model.loadDetail(id: summary.id, connection: connections.active) }
        }
    }
}

// MARK: - SystemRow

struct SystemRow: View {

    let summary: SystemSummary
    /// nil while the detail is still loading.
    let system: RemoteSystem?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: system.map { SystemGlyph.symbol(for: $0) } ?? "shippingbox")
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(system == nil ? .secondary : .primary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.name)
                    .lineLimit(2)
                Text(summary.uid ?? summary.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                badges
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var badges: some View {
        if let system {
            HStack(spacing: 6) {
                badge("\(system.datastreams.count) datastreams", "waveform")
                if !system.subsystems.isEmpty {
                    badge("\(system.subsystems.count) subsystems", "square.stack.3d.up")
                }
                if system.controlStreamCount > 0 {
                    badge("\(system.controlStreamCount) control", "slider.horizontal.3")
                }
                if system.datastreams.contains(where: { $0.schemaError != nil }) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("some schemas not understood")
                }
            }
        } else {
            // A placeholder the same height as the badges, so the row does not
            // resize under the user's thumb when the detail lands.
            Text("loading…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .redacted(reason: .placeholder)
        }
    }

    private func badge(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }
}

// MARK: - SystemBrowserModel

/// Listing plus lazily-loaded detail, in one observable place.
@MainActor
final class SystemBrowserModel: ObservableObject {

    @Published private(set) var systems: [SystemSummary] = []
    @Published private(set) var loaded: [String: RemoteSystem] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private let loader = RemoteSystemLoader()
    /// Ids already being fetched, so a row that reappears while scrolling does
    /// not queue a second identical request.
    private var inFlight: Set<String> = []

    func load(connection: NodeConnection?, refresh: Bool = false) async {
        guard let connection else {
            systems = []
            error = "Select a server on the Node tab first."
            return
        }
        isLoading = true
        defer { isLoading = false }

        if refresh {
            await loader.invalidate(serverId: connection.server.id)
            loaded.removeAll()
        }

        do {
            systems = try await connection.readClient.listSystems(limit: 200)
            error = nil
        } catch {
            self.error = error.localizedDescription
            Log.client.error("System listing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadDetail(id: String, connection: NodeConnection?) async {
        guard let connection, loaded[id] == nil, !inFlight.contains(id) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        let result = await loader.load(systemId: id,
                                       using: connection.readClient,
                                       serverId: connection.server.id)
        if case .success(let system) = result {
            loaded[id] = system
        }
    }
}
