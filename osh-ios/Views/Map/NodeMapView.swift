import SwiftUI

// MARK: - NodeMapView
//
// The "Node" half of the Map tab: every positioned system on the node, with its
// bearing lines, and a sheet per marker.

struct NodeMapView: View {

    @EnvironmentObject private var connections: NodeConnectionStore
    @StateObject private var model = NodeMapModel()

    @State private var selected: RemoteSystem?

    var body: some View {
        ZStack {
            SystemMapView(markers: model.markers,
                          bearingLines: model.bearingLines,
                          onSelect: { marker in selected = system(for: marker) })

            if model.markers.isEmpty {
                overlayMessage
            }
        }
        .safeAreaInset(edge: .bottom) { legend }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $model.isLive) {
                    Label("Live", systemImage: model.isLive ? "dot.radiowaves.up.forward" : "pause")
                }
                .toggleStyle(.button)
            }
        }
        .task(id: connections.active?.server.id) {
            await model.load(connection: connections.active)
        }
        .onDisappear { model.stopAll() }
        .sheet(item: $selected) { system in
            SystemMarkerSheet(system: system, model: model)
        }
    }

    private func system(for marker: SystemMapView.Marker) -> RemoteSystem? {
        let systemId = marker.id.split(separator: "#").first.map(String.init) ?? marker.id
        return model.systems.first { $0.id == systemId }
    }

    // MARK: Chrome

    @ViewBuilder
    private var overlayMessage: some View {
        if model.isLoading {
            ProgressView("Loading systems…")
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if let error = model.error {
            ContentUnavailableView {
                Label("Cannot read the node", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
            .background(.regularMaterial)
        } else {
            ContentUnavailableView {
                Label("No positioned systems", systemImage: "mappin.slash")
            } description: {
                Text("None of the systems on this node reports a location.")
            }
            .background(.regularMaterial)
        }
    }

    @ViewBuilder
    private var legend: some View {
        if !model.markers.isEmpty {
            HStack(spacing: 10) {
                Text("\(model.markers.count) markers")
                if !model.bearingLines.isEmpty {
                    Label("\(model.bearingLines.count) LOB", systemImage: "line.diagonal")
                        .foregroundStyle(.orange)
                }
                if model.didDecimate {
                    // Said out loud rather than silently truncated: a partial
                    // harbour that looks complete is worse than a full one.
                    Label("showing the newest \(NodeMapModel.maxMarkers)",
                          systemImage: "line.3.horizontal.decrease")
                }
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial)
        }
    }
}

// MARK: - SystemMarkerSheet

/// What a tapped marker says about its system.
///
/// Cards in the same order as the dashboard — status, then bearing, then the
/// rest — so a KrakenSDR reads "here is the station, here is what it heard"
/// whichever screen it is on.
struct SystemMarkerSheet: View {

    let system: RemoteSystem
    @ObservedObject var model: NodeMapModel
    @EnvironmentObject private var connections: NodeConnectionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let session = model.session(for: system.id) {
                        ForEach(DashboardOrder.order(system.datastreams)) { datastream in
                            DatastreamCard(datastream: datastream, session: session)
                        }
                    } else {
                        ForEach(DashboardOrder.order(system.datastreams)) { datastream in
                            StaticDatastreamSummary(
                                datastream: datastream,
                                observation: model.newest(systemId: system.id,
                                                          datastreamId: datastream.id))
                        }
                    }

                    if let connection = connections.active {
                        NavigationLink {
                            SystemDashboardView(system: system, connection: connection)
                        } label: {
                            Label("Open dashboard", systemImage: "square.grid.2x2")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(system.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - StaticDatastreamSummary

/// A datastream with no live session behind it — the Live toggle is off, or the
/// system did not make the subscription cap. Shows the one archived
/// observation, which for a bearing or a settings record is the whole story
/// anyway.
struct StaticDatastreamSummary: View {

    let datastream: RemoteDatastream
    let observation: ParsedObservation?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: SystemGlyph.symbol(for: datastream.role))
                    .foregroundStyle(.secondary)
                Text(datastream.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            if case .bearing(let paths) = datastream.role,
               let angle = observation?.values[paths.angle]?.asDouble {
                HStack(alignment: .top, spacing: 12) {
                    HeadingDialView(headingDegrees: angle, needle: .ray, tint: .orange)
                        .frame(width: 80, height: 80)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.1f°", angle))
                            .font(.title3.monospacedDigit().weight(.semibold))
                        if let observation {
                            AsOfLabel(timestamp: observation.phenomenonTime, prominent: true)
                        }
                    }
                    Spacer()
                }
            } else if let record = datastream.recordSchema {
                FieldRowsView(leaves: FieldRowsView.valueLeaves(of: record),
                              latest: observation,
                              showSparklines: false,
                              emptyText: "no archived observation")
                if let observation {
                    AsOfLabel(timestamp: observation.phenomenonTime)
                }
            } else if let schemaError = datastream.schemaError {
                Label(schemaError, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }
}
