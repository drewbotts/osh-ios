import SwiftUI
import Charts

// MARK: - FieldRowsView
//
// One labelled row per leaf, with a sparkline under any row that has moved.
//
// Lifted out of SensorCard in Pass 3b unchanged, because it turned out to be
// the fallback for the whole viewer: a timeseries card, a generic card and a
// card for a schema nobody has ever seen all render this, and the Live tab
// still renders exactly what it did before.

struct FieldRowsView: View {

    let leaves: [SchemaWalker.Leaf]
    let latest: ParsedObservation?
    /// Observations behind the sparklines. Empty for a latest-only card.
    var history: [ParsedObservation] = []
    var showSparklines = true
    var emptyText = "waiting for data"

    var body: some View {
        if leaves.isEmpty {
            Text(emptyText)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(leaves, id: \.path) { leaf in
                    row(leaf)
                }
            }
        }
    }

    private func row(_ leaf: SchemaWalker.Leaf) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.label(for: leaf))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(Self.valueText(for: leaf, in: latest))
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
            }

            if showSparklines {
                let samples = samples(for: leaf.path)
                if samples.count >= 2 {
                    Sparkline(values: samples)
                        .frame(height: 28)
                }
            }
        }
    }

    private func samples(for path: FieldPath) -> [Double] {
        history.compactMap { $0.values[path]?.asDouble }.filter(\.isFinite)
    }

    // MARK: Formatting

    static func label(for leaf: SchemaWalker.Leaf) -> String {
        leaf.component.label ?? leaf.path.lastComponent
    }

    /// The value with its unit, or an em dash when the observation is missing
    /// that leaf. "1" is SWE's unitless code and is never shown.
    static func valueText(for leaf: SchemaWalker.Leaf, in observation: ParsedObservation?) -> String {
        guard let value = observation?.values[leaf.path] else { return "—" }
        guard let number = value.asDouble else { return value.asString }

        let formatted = String(format: "%.2f", number)
        if let quantity = leaf.component as? Quantity, quantity.uom != "1" {
            return "\(formatted) \(quantity.uom)"
        }
        return formatted
    }

    /// Every leaf except the time field.
    ///
    /// A timestamp row would appear on every card and say nothing about the
    /// sensor; the card header carries the time when it matters.
    static func valueLeaves(of record: DataRecord) -> [SchemaWalker.Leaf] {
        SchemaWalker.leaves(of: record).filter { !($0.component is TimeComponent) }
    }
}

// MARK: - Sparkline

/// A short trace with no axes, gridlines or labels. It is there to show shape
/// and movement; the exact value is already on the row above it.
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
