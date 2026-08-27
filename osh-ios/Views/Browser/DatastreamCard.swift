import SwiftUI
import Charts
import CoreLocation

// MARK: - DatastreamCard
//
// One datastream on the dashboard, drawn according to its role. This is where
// the inference cashes out: nothing below chooses a body by name or by driver,
// only by what the schema turned out to be.

struct DatastreamCard: View {

    let datastream: RemoteDatastream
    @ObservedObject var session: SystemLiveSession
    var onExpandMap: ((RemoteDatastream) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            roleBody(for: datastream.role)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(datastream.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Image(systemName: SystemGlyph.symbol(for: datastream.role))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                // The drill-down closes the gap Pass 3a left: the decoded
                // schema tree and the last ten raw observations were reachable
                // only for this device's own datastreams.
                NavigationLink {
                    DatastreamDetailView(datastream: datastream.summary)
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Schema and raw observations")
            }
            if let entityCount, entityCount > 1 {
                Text("\(entityCount) entities")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(datastream.name), \(datastream.role.label)")
    }

    private var state: SystemLiveSession.StreamState {
        session.streamState[datastream.id] ?? .idle
    }

    private var stateColor: Color {
        switch state {
        case .streaming:    return .green
        case .connecting:   return .orange
        case .disconnected: return .red
        case .idle:         return .secondary
        }
    }

    private var entityCount: Int? {
        guard datastream.entityKeyPath != nil else { return nil }
        return session.latest[datastream.id]?.count
    }

    // MARK: Bodies

    @ViewBuilder
    private func roleBody(for role: DatastreamRole) -> some View {
        if let schemaError = datastream.schemaError {
            VStack(alignment: .leading, spacing: 4) {
                Label("schema not understood", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(schemaError)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            switch role {
            case .location(let paths, let headingPath):
                locationBody(paths, headingPath: headingPath)
            case .orientation(let paths):
                orientationBody(paths)
            case .bearing(let paths):
                bearingBody(paths)
            case .video(let compression):
                videoCardBody(compression: compression)
            case .chart(let paths):
                ChartCardBody(datastream: datastream, paths: paths, session: session)
            case .timeseries, .generic:
                fieldsBody(showSparklines: true)
            case .status:
                statusBody
            }
        }
    }

    // MARK: Location

    @ViewBuilder
    private func locationBody(_ paths: LocationPaths, headingPath: FieldPath?) -> some View {
        let entities = session.entities(datastreamId: datastream.id)
        let markers = LocationCardModel.markers(entities: entities,
                                                paths: paths,
                                                headingPath: headingPath,
                                                symbol: SystemGlyph.symbol(for: datastream.role),
                                                fallbackId: datastream.id)

        VStack(alignment: .leading, spacing: 6) {
            if markers.isEmpty {
                Text("waiting for a fix")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // A track is only drawn for a single-entity stream. Joining an
                // AIS ring's points would draw a line between whichever vessels
                // happened to transmit consecutively.
                let tracks = datastream.entityKeyPath == nil
                    ? [LocationCardModel.track(session.history[datastream.id] ?? [], paths: paths)]
                    : []

                SystemMapView(markers: markers,
                              tracks: tracks.filter { $0.count >= 2 },
                              showsControls: false,
                              isInteractive: false)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture { onExpandMap?(datastream) }

                if entities.count == 1, let first = entities.first {
                    LocationSummaryView(paths: paths, observation: first.observation)
                }
            }
        }
    }

    // MARK: Orientation

    @ViewBuilder
    private func orientationBody(_ paths: OrientationPaths) -> some View {
        let observation = session.newest(datastreamId: datastream.id)
        let heading = observation.flatMap { paths.heading(from: $0) }

        HStack(alignment: .top, spacing: 12) {
            HeadingDialView(headingDegrees: heading)
                .frame(width: 92, height: 92)

            VStack(alignment: .leading, spacing: 4) {
                Text(heading.map { String(format: "%.1f°", $0) } ?? "—")
                    .font(.title3.monospacedDigit().weight(.semibold))
                if let observation {
                    if let pitch = paths.pitch(from: observation) {
                        angleRow("pitch", pitch)
                    }
                    if let roll = paths.roll(from: observation) {
                        angleRow("roll", roll)
                    }
                    AsOfLabel(timestamp: observation.phenomenonTime)
                } else {
                    Text("waiting for data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func angleRow(_ label: String, _ degrees: Double) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "%.1f°", degrees))
                .font(.caption.monospacedDigit())
        }
    }

    // MARK: Bearing

    @ViewBuilder
    private func bearingBody(_ paths: BearingPaths) -> some View {
        let observation = session.newest(datastreamId: datastream.id)
        let angle = observation?.values[paths.angle]?.asDouble

        HStack(alignment: .top, spacing: 12) {
            HeadingDialView(headingDegrees: angle,
                            needle: .ray,
                            tint: .orange,
                            opacity: observation.map {
                                BearingStyle.opacity(at: $0.phenomenonTime)
                                    / BearingStyle.freshOpacity
                            } ?? 1)
                .frame(width: 92, height: 92)

            VStack(alignment: .leading, spacing: 4) {
                if let angle {
                    Text(String(format: "%.1f°", angle))
                        .font(.title2.monospacedDigit().weight(.semibold))
                    if let qualityPath = paths.quality,
                       let quality = observation?.values[qualityPath]?.asDouble {
                        Text(String(format: "quality %.2f", quality))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    // Prominent, because a DOA stream emits only on detection:
                    // the reading on screen may be minutes or days old and is
                    // still the answer.
                    if let observation {
                        AsOfLabel(timestamp: observation.phenomenonTime, prominent: true)
                    }
                } else {
                    Text("no detections yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Video

    @ViewBuilder
    private func videoCardBody(compression: String?) -> some View {
        let isPlaying = state.isLive
        if MJPEGDecoder.isH264(compression: compression) {
            UnsupportedCodecView(compression: compression,
                                 stats: session.blockStats[datastream.id],
                                 isPlaying: isPlaying,
                                 onPlay: { session.start(datastreamId: datastream.id) },
                                 onPause: { session.stop(datastreamId: datastream.id) })
        } else {
            MJPEGView(latestFrame: session.frames[datastream.id],
                      stats: session.blockStats[datastream.id],
                      compression: compression,
                      isPlaying: isPlaying,
                      onPlay: { session.start(datastreamId: datastream.id) },
                      onPause: { session.stop(datastreamId: datastream.id) })
        }
    }

    // MARK: Fields and status

    @ViewBuilder
    private func fieldsBody(showSparklines: Bool) -> some View {
        if let record = datastream.recordSchema {
            FieldRowsView(leaves: FieldRowsView.valueLeaves(of: record),
                          latest: session.newest(datastreamId: datastream.id),
                          history: showSparklines ? (session.history[datastream.id] ?? []) : [],
                          showSparklines: showSparklines)
        } else {
            Text("no schema")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A settings dump, grouped the way the record groups it.
    ///
    /// No sparklines: a configuration value that changed is news, and a plot of
    /// a constant is not.
    @ViewBuilder
    private var statusBody: some View {
        if let record = datastream.recordSchema {
            let observation = session.newest(datastreamId: datastream.id)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(StatusGroup.groups(of: record), id: \.title) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        if let title = group.title {
                            Text(title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                        }
                        FieldRowsView(leaves: group.leaves,
                                      latest: observation,
                                      showSparklines: false)
                    }
                }
                if let observation {
                    AsOfLabel(timestamp: observation.phenomenonTime)
                }
            }
        }
    }
}

// MARK: - StatusGroup

/// A status record's leaves, grouped by the nested record they came from.
///
/// A KrakenSDR settings dump is thirty fields across four sub-records; a flat
/// list of thirty rows is technically the same information and unreadable.
struct StatusGroup {
    /// nil for the leaves sitting at the record's own top level.
    let title: String?
    let leaves: [SchemaWalker.Leaf]

    static func groups(of record: DataRecord) -> [StatusGroup] {
        var groups: [StatusGroup] = []

        let topLevel = record.fields
            .filter { !($0.component is DataRecord) }
            .flatMap { field -> [SchemaWalker.Leaf] in
                collect(field.component, at: FieldPath(components: [field.name]))
            }
            .filter { !($0.component is TimeComponent) }
        if !topLevel.isEmpty { groups.append(StatusGroup(title: nil, leaves: topLevel)) }

        for field in record.fields {
            guard let nested = field.component as? DataRecord else { continue }
            let leaves = collect(nested, at: FieldPath(components: [field.name]))
                .filter { !($0.component is TimeComponent) }
            guard !leaves.isEmpty else { continue }
            groups.append(StatusGroup(title: nested.label ?? field.name, leaves: leaves))
        }
        return groups
    }

    private static func collect(_ component: DataComponent, at path: FieldPath)
        -> [SchemaWalker.Leaf] {
        switch component {
        case let record as DataRecord:
            return record.fields.flatMap { collect($0.component, at: path.appending($0.name)) }
        case let vector as SWEVector:
            return vector.coordinates.flatMap { collect($0.component, at: path.appending($0.name)) }
        default:
            return [SchemaWalker.Leaf(path: path, component: component)]
        }
    }
}

// MARK: - AsOfLabel

/// When a reading was taken. Used wherever "now" cannot be assumed — which is
/// every latest-only card, and emphatically the bearing one.
struct AsOfLabel: View {
    let timestamp: Date
    var prominent = false

    var body: some View {
        Text("as of \(timestamp.formatted(date: .abbreviated, time: .standard))")
            .font(prominent ? .caption.weight(.medium) : .caption2)
            .foregroundStyle(prominent && isStale ? .orange : .secondary)
    }

    private var isStale: Bool {
        Date().timeIntervalSince(timestamp) > BearingStyle.staleAfter
    }
}

// MARK: - ChartCardBody

/// A spectrum, as a waterfall or as a line.
///
/// The waterfall is the default when the x-axis is a frequency, because that is
/// what an SDR display is and because a single spectrum line says nothing about
/// whether a signal is intermittent. Other charts — a depth profile, a
/// histogram — have no time dimension worth scrolling and show the line.
struct ChartCardBody: View {

    let datastream: RemoteDatastream
    let paths: ChartPaths
    @ObservedObject var session: SystemLiveSession

    @State private var mode: Mode?

    enum Mode: String, CaseIterable { case waterfall = "Waterfall", spectrum = "Spectrum" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isFrequencyChart {
                Picker("Display", selection: Binding(
                    get: { mode ?? .waterfall },
                    set: { mode = $0 })) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if let seriesPath = paths.series.first {
                if isFrequencyChart && (mode ?? .waterfall) == .waterfall {
                    WaterfallView(observations: session.history[datastream.id] ?? [],
                                  seriesPath: seriesPath,
                                  columnCount: 512)
                } else {
                    SpectrumLine(observation: session.newest(datastreamId: datastream.id),
                                 seriesPath: seriesPath,
                                 xAxisPath: paths.xAxis)
                }
            } else {
                Text("no series to plot")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isFrequencyChart: Bool {
        guard let xAxis = paths.xAxis, let record = datastream.recordSchema else { return false }
        return DatastreamRoleInference.isFrequencyAxis(xAxis, in: record)
    }
}

// MARK: - SpectrumLine

/// The latest observation as a line: the x-axis array against the series.
struct SpectrumLine: View {

    let observation: ParsedObservation?
    let seriesPath: FieldPath
    let xAxisPath: FieldPath?

    var body: some View {
        if let points, points.count >= 2 {
            Chart(points, id: \.x) { point in
                LineMark(x: .value("x", point.x), y: .value("y", point.y))
            }
            .chartLegend(.hidden)
            .frame(height: 150)
        } else {
            Text("waiting for a spectrum")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 150, alignment: .center)
        }
    }

    private var points: [(x: Double, y: Double)]? {
        guard let observation else { return nil }
        let series = SeriesReader.values(of: observation, at: seriesPath)
        guard !series.isEmpty else { return nil }

        let axis = xAxisPath.map { SeriesReader.values(of: observation, at: $0) } ?? []
        return series.enumerated().map { index, value in
            (x: index < axis.count ? axis[index] : Double(index), y: value)
        }
        .filter { $0.x.isFinite && $0.y.isFinite }
    }
}

// MARK: - LocationCardModel

/// Turns a location datastream's entities into map inputs.
///
/// Pulled out of the view so the map card, the full-screen expansion and the
/// Node map all build markers the same way — and so the rules can be tested
/// without a map.
enum LocationCardModel {

    static func markers(entities: [(key: String, observation: ParsedObservation)],
                        paths: LocationPaths,
                        headingPath: FieldPath?,
                        symbol: String,
                        fallbackId: String) -> [SystemMapView.Marker] {
        entities.compactMap { entity in
            guard let point = TrackPoint.from(entity.observation, paths: paths, accuracy: nil)
            else { return nil }
            return SystemMapView.Marker(
                id: entity.key.isEmpty ? fallbackId : entity.key,
                coordinate: point.coordinate,
                symbol: symbol,
                headingDegrees: headingPath.flatMap { entity.observation.values[$0]?.asDouble },
                kind: .live,
                label: entity.key.isEmpty ? nil : entity.key)
        }
    }

    static func track(_ observations: [ParsedObservation],
                      paths: LocationPaths) -> [CLLocationCoordinate2D] {
        observations
            .compactMap { TrackPoint.from($0, paths: paths, accuracy: nil)?.coordinate }
    }
}
