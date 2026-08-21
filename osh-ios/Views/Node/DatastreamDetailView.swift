import SwiftUI
import UIKit

// MARK: - DatastreamDetailView
//
// The summary fields, plus the datastream's schema document fetched raw.
//
// The schema is shown as pretty-printed JSON rather than decoded: a SWE schema
// is richer than the DataRecord model this app builds for its own outputs, and
// a lossy decode would hide exactly the parts a viewer will need. Raw text is
// honest about that, and copyable. A later pass adds real SWE decoding.

struct DatastreamDetailView: View {

    let datastream: DatastreamSummary

    @EnvironmentObject private var connections: NodeConnectionStore

    @State private var schemaText: String?
    @State private var schemaError: String?
    @State private var isFetching = false

    /// The SWE JSON schema media type. The node also serves swe+csv and
    /// swe+binary variants of the same document.
    private static let schemaFormat = "application/swe+json"

    var body: some View {
        List {
            summarySection
            timeSection
            schemaSection
        }
        .navigationTitle(datastream.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Summary

    private var summarySection: some View {
        Section("Datastream") {
            detailRow("Name", datastream.name)
            detailRow("ID", datastream.id, monospaced: true)
            if let outputName = datastream.outputName {
                detailRow("Output name", outputName, monospaced: true)
            }
            if let systemId = datastream.systemId {
                detailRow("System ID", systemId, monospaced: true)
            }
            if let formats = datastream.formats, !formats.isEmpty {
                detailRow("Formats", formats.joined(separator: "\n"))
            }
            if let live = datastream.live {
                detailRow("Live", live ? "yes" : "no")
            }
        }
    }

    @ViewBuilder
    private var timeSection: some View {
        let ranges: [(String, [String]?)] = [
            ("Valid time", datastream.validTime),
            ("Phenomenon time", datastream.phenomenonTimeRange),
            ("Result time", datastream.resultTimeRange)
        ]
        let present = ranges.filter { !($0.1?.isEmpty ?? true) }
        if !present.isEmpty {
            Section("Time") {
                ForEach(present, id: \.0) { label, values in
                    detailRow(label, (values ?? []).joined(separator: " → "))
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Schema

    @ViewBuilder
    private var schemaSection: some View {
        Section {
            Button {
                Task { await fetchSchema() }
            } label: {
                HStack {
                    Text(schemaText == nil ? "Fetch schema" : "Refresh schema")
                    Spacer()
                    if isFetching { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isFetching || connections.active == nil)

            if let schemaError {
                Label(schemaError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if let schemaText {
                ScrollView([.horizontal, .vertical]) {
                    Text(schemaText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }
                .frame(height: 320)

                Button("Copy JSON", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = schemaText
                }
            }
        } header: {
            Text("Schema")
        } footer: {
            Text("Raw \(Self.schemaFormat) document, pretty-printed. SWE decoding lands in a later pass.")
        }
    }

    private func fetchSchema() async {
        guard let connection = connections.active else { return }
        isFetching = true
        defer { isFetching = false }
        do {
            let data = try await connection.readClient.getDatastreamSchemaJSON(
                id: datastream.id,
                obsFormat: Self.schemaFormat)
            schemaText = Self.prettyPrinted(data)
            schemaError = nil
        } catch {
            schemaError = error.localizedDescription
            Log.client.error("Schema fetch failed for \(datastream.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-serialises with sorted keys and indentation. A body that is not JSON
    /// at all is shown verbatim rather than replaced by an error — seeing what
    /// the node actually returned is the point.
    private static func prettyPrinted(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                    options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .utf8) ?? "<\(data.count) bytes, not UTF-8>"
    }
}

#Preview {
    NavigationStack {
        DatastreamDetailView(datastream: PreviewSupport.datastreams[0])
    }
    .previewEnvironment()
}
