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
    /// What a `.target` card needs to name the system a target was observed
    /// from. Absent everywhere else, and absent even here when the host has no
    /// system list to resolve against — the card then says what the record
    /// says and nothing more.
    var targetContext: TargetCardContext?

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
                ActivityDot(state: activity.state, lastObservation: activity.lastObservation)
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
            HStack(spacing: 6) {
                if let text = ActivityText.relative(activity.lastObservation) {
                    Text(text)
                }
                if let socket = socketText {
                    Text("· \(socket)")
                }
                if let entityCount, entityCount > 1 {
                    Text("· \(entityCount) entities")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(datastream.name), \(datastream.role.label), \(ActivityText.accessibility(state: activity.state, lastObservation: activity.lastObservation))")
    }

    private var state: SystemLiveSession.StreamState {
        session.streamState[datastream.id] ?? .idle
    }

    /// The socket's own state, said in words and only when it is worth saying.
    ///
    /// Freshness and connectivity are two facts and the dot can only carry one.
    /// The dot carries freshness because that is what the user is looking at
    /// the card for; a socket that is merely connecting or has dropped is worth
    /// a word, and a socket that is happily streaming is worth nothing at all.
    private var socketText: String? {
        switch state {
        case .streaming:              return nil
        case .connecting:             return "connecting"
        case .idle:                   return "not subscribed"
        case .disconnected(let text): return text.map { "disconnected: \($0)" } ?? "disconnected"
        }
    }

    /// This datastream's own freshness: the newest observation the session has,
    /// falling back to what the node reported at load for a stream nothing has
    /// subscribed to yet.
    private var activity: SystemActivity {
        let newest = session.newest(datastreamId: datastream.id)?.phenomenonTime
            ?? SystemActivity.endOfRange(datastream.summary, openEndedAs: Date())
        return SystemActivity(state: ActivityState.of(newest, now: Date()),
                              lastObservation: newest)
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
            case .target(let paths):
                targetBody(paths)
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

    // MARK: Target

    /// A designated target: where it is, how far and which way, and who was
    /// looking.
    ///
    /// No map tile. The point of a target is the *pair* of positions, and a
    /// 150-point card cannot show a line between two points a kilometre apart
    /// and remain readable — the COP map is where that lives, which is what the
    /// source name links to.
    @ViewBuilder
    private func targetBody(_ paths: TargetPaths) -> some View {
        let entities = session.entities(datastreamId: datastream.id)

        if entities.isEmpty {
            Text("no targets designated yet")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(entities, id: \.key) { entity in
                    TargetSummaryView(paths: paths,
                                      observation: entity.observation,
                                      entityKey: entity.key,
                                      source: source(for: entity.observation, paths: paths),
                                      onSelectSource: targetContext?.onSelectSource)
                }
            }
        }
    }

    /// The system this target was observed from, when the host gave us enough
    /// to work it out.
    private func source(for observation: ParsedObservation,
                        paths: TargetPaths) -> TargetSourceResolver.SourceRef? {
        let context = targetContext ?? TargetCardContext()
        // The owner is always a candidate even when the host passed no list:
        // rules iii and v need nothing else.
        var systems = context.systems
        if !systems.contains(where: { $0.id == session.system.id }) {
            systems.append(session.system)
        }
        return TargetSourceResolver.source(for: observation,
                                           datastream: datastream,
                                           owner: session.system,
                                           systems: systems,
                                           localDevice: context.localDevice)
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

// MARK: - TargetCardContext

/// What a host screen lends a `.target` card so it can name the target's
/// source.
///
/// Passed in rather than fetched because the systems are already loaded
/// somewhere: the COP map holds every system on the node, and the systems list
/// hands its own down to the dashboard. A card that went and loaded them again
/// would be a second copy and a second failure mode for a system *name*.
struct TargetCardContext {
    var systems: [RemoteSystem] = []
    var localDevice: TargetSourceResolver.LocalDeviceRef?
    /// Sends the user to the source on the map. nil makes the name plain text.
    var onSelectSource: ((TargetSourceResolver.SourceRef) -> Void)?
}

// MARK: - TargetSummaryView

/// One designated target, in words.
///
/// Shared by the dashboard's target card and the map sheet's static summary so
/// a target reads the same whether or not a socket is open behind it.
struct TargetSummaryView: View {

    let paths: TargetPaths
    let observation: ParsedObservation
    var entityKey: String = ""
    let source: TargetSourceResolver.SourceRef?
    let onSelectSource: ((TargetSourceResolver.SourceRef) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: SystemGlyph.targetMarkerSymbol)
                    .foregroundStyle(.red)
                Text(headline)
                    .font(.title3.monospacedDigit().weight(.semibold))
                Spacer(minLength: 0)
            }

            LocationSummaryView(paths: paths.location, observation: observation)

            if let elevation = value(paths.elevation) {
                angleRow("elevation", elevation)
            }
            if let azimuth = value(paths.azimuth), value(paths.range) == nil {
                // Only when the headline did not already say it.
                angleRow("azimuth", azimuth)
            }

            sourceRow

            // Prominent for the same reason a LOB's is: a range finder fires
            // when someone pulls the trigger, and the reading on screen may be
            // hours old and still be the answer.
            AsOfLabel(timestamp: observation.phenomenonTime, prominent: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Range and azimuth when the record carries them, else what the target is
    /// called, else just "Target".
    private var headline: String {
        TargetStyle.label(rangeMeters: value(paths.range),
                          azimuthDegrees: value(paths.azimuth))
            ?? (entityKey.isEmpty ? "Target" : entityKey)
    }

    @ViewBuilder
    private var sourceRow: some View {
        if let source {
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("from")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let onSelectSource {
                    Button(source.name) { onSelectSource(source) }
                        .font(.caption.weight(.medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                } else {
                    Text(source.name)
                        .font(.caption.weight(.medium))
                }
                if !source.hasPosition {
                    Text("· position unknown")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func value(_ path: FieldPath?) -> Double? {
        guard let path, let value = observation.values[path]?.asDouble, value.isFinite
        else { return nil }
        return value
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
