import SwiftUI

// MARK: - DeviceDatastreamsView
//
// What this device has registered on the node, and what it is sending right
// now.
//
// Pushed from the Systems tab's registration section rather than living in a
// tab of its own. It is the one screen that is about the *device's* side of the
// relationship — a datastream here is one this phone created — which is why it
// is not merged into the node's system list, where a row means "somebody else's
// sensor".

struct DeviceDatastreamsView: View {

    let systemId: String

    @EnvironmentObject private var connections: NodeConnectionStore
    @EnvironmentObject private var session: SensorSession

    @State private var datastreams: [DatastreamSummary] = []
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        List {
            if isLoading && datastreams.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Loading…") }
                    .foregroundStyle(.secondary)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if datastreams.isEmpty {
                Text("No datastreams on this system yet. Start a session to create them.")
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
        .navigationTitle("This Device")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: systemId) { await load() }
    }

    /// Live counters, but only for a datastream this session is actually
    /// feeding — a stream from an earlier run has no numbers to show.
    private func localStats(for datastream: DatastreamSummary) -> StreamStats? {
        guard case .streaming = session.state else { return nil }
        let name = datastream.outputName ?? datastream.name
        return session.sensors[name]?.stats
    }

    private func load() async {
        guard let connection = connections.active, !systemId.isEmpty else {
            datastreams = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            datastreams = try await connection.readClient.listDatastreams(systemId: systemId)
            error = nil
        } catch {
            self.error = error.localizedDescription
            Log.client.error("Datastream listing failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - DatastreamRow

struct DatastreamRow: View {

    let datastream: DatastreamSummary
    let stats: StreamStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                ActivityDot(state: ActivityState.of(
                    SystemActivity.endOfRange(datastream, openEndedAs: Date()),
                    now: Date()))
                Text(datastream.name)
            }
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

#Preview("Datastream row") {
    List {
        DatastreamRow(datastream: PreviewSupport.datastreams[0],
                      stats: StreamStats(observations: 412, bytes: 39_552, errors: 0, rate: 1))
        DatastreamRow(datastream: PreviewSupport.datastreams[1], stats: nil)
    }
}
