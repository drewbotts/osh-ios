import SwiftUI
import Charts

// MARK: - WaterfallView
//
// An SDR waterfall: time down the screen, frequency across it, amplitude as
// colour. One Image, redrawn from a CGImage the buffer produces — no per-pixel
// views, no Charts, no shape per bin.
//
// The buffer work happens off the main actor and only the finished CGImage
// crosses back, which is what keeps a 4096-bin stream at 10 Hz from stuttering
// the rest of the dashboard.

struct WaterfallView: View {

    /// Newest-first observations. The view takes the whole history rather than
    /// a delta so it can rebuild after a datastream change or a rotation
    /// without the caller tracking what it has already been told.
    let observations: [ParsedObservation]
    let seriesPath: FieldPath
    /// Element count of the widest row seen, for the resample width.
    var columnCount = 512

    @State private var image: CGImage?
    @State private var range: ClosedRange<Double> = 0...1
    @State private var renderer = WaterfallRenderer()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.85))
                if let image {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("waiting for spectra")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 160)
            .accessibilityLabel("Waterfall, \(observations.count) spectra")

            HStack {
                Text(String(format: "%.0f dB", range.lowerBound))
                Spacer()
                Text(String(format: "%.0f dB", range.upperBound))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .task(id: observations.count) { await render() }
        .task(id: seriesPath) {
            await renderer.reset(columnCount: columnCount)
            await render()
        }
    }

    /// Feeds whatever is new into the buffer and publishes the result.
    private func render() async {
        let series = observations.map { SeriesReader.values(of: $0, at: seriesPath) }
        guard let result = await renderer.append(series) else { return }
        image = result.image
        range = result.range
    }
}

// MARK: - WaterfallRenderer

/// The buffer, isolated off the main actor.
///
/// An actor rather than a `@State` struct because appending a row and rebuilding
/// a 512×200 image is milliseconds of work, and a dashboard runs several cards
/// at once.
actor WaterfallRenderer {

    private var buffer = WaterfallBuffer()
    /// How many of the caller's observations have already been drawn.
    private var consumed = 0

    struct Result: Sendable {
        let image: CGImage?
        let range: ClosedRange<Double>
    }

    func reset(columnCount: Int) {
        buffer = WaterfallBuffer(columnCount: columnCount)
        consumed = 0
    }

    /// Appends the rows not yet seen and returns the new image.
    ///
    /// - Parameter series: every row the caller holds, oldest first. A shorter
    ///   array than last time means the caller's ring dropped rows or the
    ///   stream restarted, so the buffer starts again rather than skipping.
    func append(_ series: [[Double]]) -> Result? {
        if series.count < consumed {
            buffer.reset()
            consumed = 0
        }
        guard series.count > consumed else { return nil }

        for row in series[consumed...] {
            buffer.append(row)
        }
        consumed = series.count

        return Result(image: buffer.makeImage(),
                      range: buffer.minimum...max(buffer.maximum, buffer.minimum + 1e-6))
    }
}

// MARK: - SeriesReader

/// Pulls a DataArray back out of a parsed observation.
///
/// The parser expands an array into one leaf per element — "/amplitude/0",
/// "/amplitude/1" — so reading the series means gathering the children of the
/// array's own path, in index order. The alternative, teaching the parser to
/// keep arrays whole, would change Pass 3a's shape for every consumer.
enum SeriesReader {

    static func values(of observation: ParsedObservation, at arrayPath: FieldPath) -> [Double] {
        let prefix = arrayPath.components
        var indexed: [(index: Int, value: Double)] = []

        for path in observation.orderedPaths {
            guard path.components.count > prefix.count,
                  Array(path.components.prefix(prefix.count)) == prefix,
                  let index = Int(path.components[prefix.count]),
                  let value = observation.values[path]?.asDouble else { continue }
            indexed.append((index, value))
        }

        if indexed.isEmpty {
            // A scalar at the path itself — a one-element "array", which some
            // nodes write for a single-bin capture.
            if let value = observation.values[arrayPath]?.asDouble { return [value] }
            return []
        }
        return indexed.sorted { $0.index < $1.index }.map(\.value)
    }
}
