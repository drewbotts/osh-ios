import SwiftUI
import Charts

// MARK: - SensorCard
//
// One live output, rendered entirely from its schema and its parsed
// observations. Nothing here asks what class produced the data — the body is
// chosen by SensorCardKind.from(schema:), labels come from the components, and
// units come from the Quantities. That is what makes this the component a
// remote-datastream viewer can reuse unchanged.

struct SensorCard: View {

    let sensor: SensorLiveState
    /// Encoder telemetry, supplied only for a video card.
    var videoStats: VideoStats?

    private var kind: SensorCardKind { SensorCardKind.from(schema: sensor.schema) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            switch kind {
            case .location(let paths): locationBody(paths)
            case .video:               videoBody
            case .fields:              fieldsBody
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(sensor.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if sensor.stats.rate > 0 {
                    Text(rateText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if case .unavailable(let reason) = sensor.availability {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(sensor.displayName), \(statusDescription)")
    }

    private var statusColor: Color {
        switch sensor.availability {
        case .active:      return .green
        case .stale:       return .orange
        case .unavailable: return .red
        }
    }

    private var statusDescription: String {
        switch sensor.availability {
        case .active:                 return "active"
        case .stale:                  return "no recent data"
        case .unavailable(let reason): return "unavailable, \(reason)"
        }
    }

    private var rateText: String {
        String(format: "%.1f/s", sensor.stats.rate)
    }

    // MARK: Location body

    @ViewBuilder
    private func locationBody(_ paths: LocationPaths) -> some View {
        if let latest = sensor.latest,
           let latitude = latest.values[paths.latitude]?.asDouble,
           let longitude = latest.values[paths.longitude]?.asDouble {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: "%.5f, %.5f", latitude, longitude))
                    .font(.callout.monospacedDigit())
                if let altitudePath = paths.altitude,
                   let altitude = latest.values[altitudePath]?.asDouble {
                    Text(String(format: "%.1f m", altitude))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            waitingText
        }
    }

    // MARK: Video body

    @ViewBuilder
    private var videoBody: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("video")
                .font(.callout)
            if let stats = videoStats, stats.hasDimensions {
                Text("\(stats.width)×\(stats.height)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f fps · dropped %d",
                            stats.encodedFPS, stats.droppedFrames))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("waiting for frames")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Fields body

    @ViewBuilder
    private var fieldsBody: some View {
        let leaves = valueLeaves
        if leaves.isEmpty {
            waitingText
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(leaves, id: \.path) { leaf in
                    fieldRow(leaf)
                }
            }
        }
    }

    private func fieldRow(_ leaf: SchemaWalker.Leaf) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label(for: leaf))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(valueText(for: leaf))
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
            }

            let samples = history(for: leaf.path)
            if samples.count >= 2 {
                Sparkline(values: samples)
                    .frame(height: 28)
            }
        }
    }

    /// Every leaf except the time field — a timestamp row would repeat on every
    /// card and say nothing about the sensor.
    private var valueLeaves: [SchemaWalker.Leaf] {
        SchemaWalker.leaves(of: sensor.schema).filter { !($0.component is TimeStamp) }
    }

    private func label(for leaf: SchemaWalker.Leaf) -> String {
        leaf.component.label ?? leaf.path.lastComponent
    }

    private func valueText(for leaf: SchemaWalker.Leaf) -> String {
        guard let value = sensor.latest?.values[leaf.path] else { return "—" }
        guard let number = value.asDouble else { return value.asString }

        let formatted = String(format: "%.2f", number)
        if let quantity = leaf.component as? Quantity, quantity.uom != "1" {
            return "\(formatted) \(quantity.uom)"
        }
        return formatted
    }

    private func history(for path: FieldPath) -> [Double] {
        sensor.history.compactMap { $0.values[path]?.asDouble }.filter(\.isFinite)
    }

    private var waitingText: some View {
        Text("waiting for data")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Sparkline

/// A 60-sample trace with no axes, gridlines or labels. It is there to show
/// shape and movement; the exact value is already on the row above it.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { index, value in
            LineMark(x: .value("Sample", index), y: .value("Value", value))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: domain)
        .accessibilityHidden(true)
    }

    /// A flat series would otherwise collapse to a zero-height scale and vanish.
    private var domain: ClosedRange<Double> {
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        if low == high {
            let pad = max(abs(low) * 0.01, 0.5)
            return (low - pad)...(high + pad)
        }
        return low...high
    }
}

#Preview("GPS") {
    SensorCard(sensor: PreviewSupport.gpsSensor())
        .padding()
}

#Preview("Euler orientation") {
    SensorCard(sensor: PreviewSupport.eulerSensor())
        .padding()
}

#Preview("Video") {
    SensorCard(sensor: PreviewSupport.videoSensor(),
               videoStats: PreviewSupport.videoStats)
        .padding()
}

#Preview("Unavailable") {
    SensorCard(sensor: PreviewSupport.unavailableSensor())
        .padding()
}
