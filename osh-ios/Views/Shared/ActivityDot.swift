import SwiftUI

// MARK: - ActivityDot
//
// The one status light in the app: green live, amber stale, red offline.
//
// It appears on map markers, systems-list rows, dashboard card headers and
// video-wall tiles, which is precisely why it is one view rather than four
// coloured circles. The state comes in as a value — the dot never derives
// freshness itself, so it cannot disagree with the tracker that did.
//
// The relative text variant is deliberately opt-in. On a marker it would be
// unreadable at pin size; in a list row it is the most useful thing there.

struct ActivityDot: View {

    let state: ActivityState
    /// Drives the "last seen 12 min ago" text and the accessibility label.
    var lastObservation: Date?
    /// Show the relative age beside the dot.
    var showsRelativeText = false
    var size: CGFloat = 8
    /// A hairline ring in the surrounding surface's colour, so the dot stays
    /// visible when it sits on a tinted marker.
    var ringColor: Color?

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Self.color(for: state))
                .frame(width: size, height: size)
                .overlay {
                    if let ringColor {
                        Circle().strokeBorder(ringColor, lineWidth: size * 0.18)
                    }
                }
            if showsRelativeText, let text = relativeText {
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Styling

    static func color(for state: ActivityState) -> Color {
        switch state {
        case .live:    return .green
        case .stale:   return .orange
        case .offline: return .red
        }
    }

    // MARK: Text

    /// "12 min ago", or nil when nothing has ever been observed.
    var relativeText: String? { ActivityText.relative(lastObservation) }

    private var accessibilityLabel: String {
        ActivityText.accessibility(state: state, lastObservation: lastObservation)
    }
}

// MARK: - ActivityText

/// The two strings an activity turns into, so the dot and the label cannot
/// word the same fact differently.
enum ActivityText {

    /// "12 min ago", or nil when nothing has ever been observed.
    static func relative(_ date: Date?) -> String? {
        guard let date else { return nil }
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func accessibility(state: ActivityState, lastObservation: Date?) -> String {
        guard let text = relative(lastObservation) else { return "\(state.label), never seen" }
        return "\(state.label), last seen \(text)"
    }

    /// nonisolated(unsafe): configured once and never mutated afterwards, and
    /// Foundation documents its formatting methods as safe for concurrent use.
    /// The same pattern the ISO formatters use.
    nonisolated(unsafe) private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

// MARK: - ActivityLabel

/// The dot with its state spelled out — for a card header or a detail row,
/// where there is room and no other legend.
struct ActivityLabel: View {

    let activity: SystemActivity

    var body: some View {
        HStack(spacing: 5) {
            ActivityDot(state: activity.state, lastObservation: activity.lastObservation)
            Text(activity.state.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(ActivityDot.color(for: activity.state))
            if activity.state != .live,
               let text = ActivityText.relative(activity.lastObservation) {
                Text("· \(text)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ActivityText.accessibility(state: activity.state,
                                                       lastObservation: activity.lastObservation))
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 14) {
        ActivityDot(state: .live, lastObservation: Date(), showsRelativeText: true)
        ActivityDot(state: .stale,
                    lastObservation: Date().addingTimeInterval(-12 * 60),
                    showsRelativeText: true)
        ActivityDot(state: .offline,
                    lastObservation: Date().addingTimeInterval(-3 * 3600),
                    showsRelativeText: true)
        ActivityDot(state: .offline, lastObservation: nil, showsRelativeText: true)
        Divider()
        ActivityLabel(activity: SystemActivity(state: .stale,
                                                lastObservation: Date().addingTimeInterval(-800)))
    }
    .padding()
}
