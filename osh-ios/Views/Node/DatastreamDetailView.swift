import SwiftUI
import UIKit

// MARK: - DatastreamDetailView
//
// The summary fields, the decoded schema, and the datastream's most recent
// observations.
//
// The schema was a raw JSON dump until Pass 3a, because nothing could decode a
// remote schema faithfully. Now that SWESchemaDecoder can, the tree is what is
// shown — but the raw document stays behind a toggle, because when a node
// serves something the decoder does not expect, the bytes are the only way to
// see what happened.

struct DatastreamDetailView: View {

    let datastream: DatastreamSummary

    @EnvironmentObject private var connections: NodeConnectionStore

    @State private var schemaText: String?
    @State private var schema: SWESchemaDecoder.DatastreamSchema?
    @State private var schemaError: String?
    @State private var isFetching = false
    @State private var showRawJSON = false

    @State private var observations: [ParsedObservation] = []
    @State private var observationError: String?
    @State private var isFetchingObservations = false

    /// The SWE JSON schema media type. The node also serves swe+csv and
    /// swe+binary variants of the same document.
    private static let schemaFormat = "application/swe+json"

    var body: some View {
        List {
            summarySection
            timeSection
            schemaSection
            observationsSection
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
                    Text(schema == nil && schemaText == nil ? "Fetch schema" : "Refresh schema")
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

            if let schema {
                SchemaTreeView(schema: schema)
                Toggle("Show raw JSON", isOn: $showRawJSON)
                    .font(.callout)
            }

            if showRawJSON || (schema == nil && schemaText != nil), let schemaText {
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
            if let schema {
                Text(schemaFooter(schema))
            } else {
                Text("Decoded from the node's \(Self.schemaFormat) document.")
            }
        }
    }

    /// Which representation is on screen, and how the observations will arrive.
    private func schemaFooter(_ schema: SWESchemaDecoder.DatastreamSchema) -> String {
        guard let encoding = schema.recordEncoding else {
            return "\(schema.obsFormat) · no binary encoding"
        }
        let codec = encoding.blockCompression.map { " · block \($0)" } ?? ""
        return "\(schema.obsFormat) · \(encoding.members.count) encoding members"
            + " · \(encoding.byteOrder.rawValue)\(codec)"
    }

    // MARK: Observations

    @ViewBuilder
    private var observationsSection: some View {
        Section {
            Button {
                Task { await fetchObservations() }
            } label: {
                HStack {
                    Text(observations.isEmpty ? "Fetch observations" : "Refresh observations")
                    Spacer()
                    if isFetchingObservations { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isFetchingObservations || connections.active == nil)

            if let observationError {
                Label(observationError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            ForEach(observations) { observation in
                ObservationRow(observation: observation)
            }
        } header: {
            Text("Last 10 observations")
        } footer: {
            Text("Most recent first.")
        }
    }

    private func fetchObservations() async {
        guard let connection = connections.active else { return }
        isFetchingObservations = true
        defer { isFetchingObservations = false }

        do {
            let decoder = try await connection.readClient.makeDecoder(datastreamId: datastream.id)
            let page = try await connection.readClient.fetchObservations(
                datastreamId: datastream.id,
                latest: true,
                limit: 10,
                format: ConnectedSystemsReadClient.omJSON,
                decoder: decoder)
            observations = page.observations.sorted { $0.phenomenonTime > $1.phenomenonTime }
            observationError = nil
        } catch {
            // A decode failure carries the path that failed, and that is the
            // part worth surfacing — "invalid value at /img" is actionable in a
            // way that "the request failed" is not.
            observationError = error.localizedDescription
            Log.client.error("Observation fetch failed for \(datastream.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fetchSchema() async {
        guard let connection = connections.active else { return }
        isFetching = true
        defer { isFetching = false }
        do {
            // The binary schema is preferred when the node serves one: it
            // carries the same recordSchema plus the member table, and a video
            // datastream has no swe+json schema at all.
            let binary = try? await connection.readClient.getDatastreamSchemaJSON(
                id: datastream.id, obsFormat: ConnectedSystemsReadClient.sweBinary)

            let data: Data
            if let binary {
                data = binary
            } else {
                data = try await connection.readClient.getDatastreamSchemaJSON(
                    id: datastream.id, obsFormat: Self.schemaFormat)
            }

            schemaText = Self.prettyPrinted(data)
            schema = try SWESchemaDecoder.decode(data)
            schemaError = nil
        } catch {
            // The document is still shown when only the decode failed: seeing
            // what the node sent is how an unsupported component gets diagnosed.
            schema = nil
            showRawJSON = true
            schemaError = error.localizedDescription
            Log.client.error("Schema decode failed for \(datastream.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

// MARK: - ObservationRow

/// One decoded observation: its time, then a row per leaf in schema order.
private struct ObservationRow: View {

    let observation: ParsedObservation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(observation.phenomenonTime
                .formatted(date: .abbreviated, time: .standard))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            ForEach(Array(observation.orderedPaths.prefix(Self.maxRows).enumerated()),
                    id: \.offset) { _, path in
                HStack(alignment: .top, spacing: 8) {
                    Text(path.description)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(observation.values[path]?.asString ?? "—")
                        .font(.caption2.monospaced())
                        .multilineTextAlignment(.trailing)
                }
            }

            if observation.orderedPaths.count > Self.maxRows {
                // A spectrum carries 2048 leaves; rendering them all would make
                // the list unusable and say nothing a summary does not.
                Text("+ \(observation.orderedPaths.count - Self.maxRows) more fields")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private static let maxRows = 24
}

#Preview {
    NavigationStack {
        DatastreamDetailView(datastream: PreviewSupport.datastreams[0])
    }
    .previewEnvironment()
}
