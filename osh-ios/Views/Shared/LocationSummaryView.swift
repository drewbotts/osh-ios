import SwiftUI

// MARK: - LocationSummaryView
//
// A fix as two lines of text: coordinates, then altitude when the schema has
// one. Deliberately not a map — it appears inside cards that are already inside
// a scrolling grid, and a map tile per card would cost more than it says.
//
// Lifted out of SensorCard in Pass 3b so the Live tab and the node dashboard
// render a position the same way.

struct LocationSummaryView: View {

    let paths: LocationPaths
    let observation: ParsedObservation?
    var emptyText = "waiting for data"

    var body: some View {
        if let latitude = observation?.values[paths.latitude]?.asDouble,
           let longitude = observation?.values[paths.longitude]?.asDouble {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: "%.5f, %.5f", latitude, longitude))
                    .font(.callout.monospacedDigit())
                if let altitudePath = paths.altitude,
                   let altitude = observation?.values[altitudePath]?.asDouble {
                    Text(String(format: "%.1f m", altitude))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text(emptyText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
