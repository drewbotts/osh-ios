import SwiftUI

// MARK: - SensorCard
//
// One live output, rendered entirely from its schema and its parsed
// observations. Nothing here asks what class produced the data — the body is
// chosen by SensorCardKind.from(schema:), labels come from the components, and
// units come from the Quantities.
//
// Pass 3b hollowed it out: the three bodies now live in Views/Shared and are
// shared with the node dashboard, which was always the point of writing them
// against a DataRecord. What is left is the header, the status colour and the
// choice between them.

struct SensorCard: View {

    let sensor: SensorLiveState
    /// Encoder telemetry, supplied only for a video card.
    var videoStats: VideoStats?

    private var kind: SensorCardKind { SensorCardKind.from(schema: sensor.schema) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            switch kind {
            case .location(let paths):
                LocationSummaryView(paths: paths, observation: sensor.latest)
            case .video:
                VideoBadgeView(stats: videoStats)
            case .fields:
                FieldRowsView(leaves: FieldRowsView.valueLeaves(of: sensor.schema),
                              latest: sensor.latest,
                              history: sensor.history)
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
