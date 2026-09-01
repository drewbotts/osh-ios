import SwiftUI

// MARK: - MarkerView
//
// One system on the map: what it is, how it is facing, and whether it is still
// talking.
//
// The redesign of HeadingMarker, and the change that matters is that the glyph
// no longer rotates. The old marker turned the whole disc to the heading, which
// meant a camera pointing south-west was drawn upside down and unreadable. Here
// the disc stays upright and an arrowhead travels round a ring outside it, so
// the icon is always legible and the bearing is still exact.
//
// Freshness arrives as a value, not as a subscription. This view is built once
// per annotation per frame and a map in a busy anchorage draws a hundred of
// them: an @EnvironmentObject here would make every marker observe the activity
// tracker and redraw the whole map whenever any one system changed colour. The
// tracker is still the source — COPMapModel reads it when it builds the
// markers — and nothing in this file owns a timer or a clock.

struct MarkerView: View {

    // MARK: Inputs

    let symbol: String
    /// Degrees clockwise from true north, or nil when nothing says.
    var headingDegrees: Double?
    var kind: RemoteSystem.PositionKind = .live
    var tint: Color = .accentColor
    var activity: ActivityState = .live
    /// Entity key or system name, drawn under the marker.
    var label: String?
    /// The map's "Labels" layer toggle.
    var showsLabel = true
    var isSelected = false
    /// Diameter of the glyph disc. The ring and label scale off it.
    var size: CGFloat = 30

    // MARK: Body

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                headingRing
                disc
                statusDot
            }
            .frame(width: ringDiameter, height: ringDiameter)

            if showsLabel, let label, !label.isEmpty {
                labelChip(label)
            }
        }
        // The only animation in the whole marker. Selection is a user action
        // and reads as unresponsive without it; everything else here changes
        // because data arrived, and animating that fights the map.
        .scaleEffect(isSelected ? 1.18 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Disc

    private var disc: some View {
        Circle()
            // A deployed position is someone's registration entry rather than
            // an observation, and it should not read as strongly as a fix.
            .fill(kind == .deployed ? tint.opacity(0.55) : tint)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                if isSelected {
                    Circle().strokeBorder(.white, lineWidth: 2)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if kind == .reported {
                    // "This system says where it is" and "this system is being
                    // tracked" are different levels of evidence for the same
                    // pin, and the badge is what keeps them apart.
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: size * 0.26, weight: .bold))
                        .foregroundStyle(tint)
                        .padding(1.5)
                        .background(.white, in: Circle())
                        .offset(x: -size * 0.14, y: size * 0.14)
                }
            }
            .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
    }

    // MARK: Status dot

    private var statusDot: some View {
        ActivityDot(state: activity,
                    size: size * 0.30,
                    ringColor: .white)
            .offset(x: size * 0.40, y: -size * 0.40)
    }

    // MARK: Heading

    private var ringDiameter: CGFloat { size * 1.62 }

    /// The arrowhead, on its ring, turned to the heading.
    ///
    /// Map-north-up: the map is not rotated, so degrees clockwise from north is
    /// a rotation of the same number of degrees. A deployed marker never turns
    /// — the system resource carries a point, not an attitude, and spinning it
    /// would invent one.
    @ViewBuilder
    private var headingRing: some View {
        if kind != .deployed, let headingDegrees, headingDegrees.isFinite {
            ZStack {
                Circle()
                    .strokeBorder(tint.opacity(0.30), lineWidth: 1.5)
                    .frame(width: ringDiameter, height: ringDiameter)
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: size * 0.30, weight: .black))
                    .foregroundStyle(tint)
                    .shadow(color: .white, radius: 0.6)
                    .offset(y: -ringDiameter / 2)
            }
            .rotationEffect(.degrees(headingDegrees))
        }
    }

    // MARK: Label

    private func labelChip(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            // Thin material rather than a solid fill: a name has to stay
            // readable over both a city block and open water.
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }

    // MARK: Accessibility

    private var accessibilityLabel: String {
        var parts: [String] = []
        if let label, !label.isEmpty { parts.append(label) }
        parts.append(kindDescription)
        parts.append(activity.label)
        if kind != .deployed, let headingDegrees, headingDegrees.isFinite {
            parts.append(String(format: "heading %.0f degrees", headingDegrees))
        }
        return parts.joined(separator: ", ")
    }

    private var kindDescription: String {
        switch kind {
        case .live:     return "live position"
        case .reported: return "reported position"
        case .deployed: return "installed position"
        }
    }
}

#Preview {
    VStack(spacing: 30) {
        HStack(spacing: 28) {
            MarkerView(symbol: "video.fill", headingDegrees: 45,
                       tint: .indigo, label: "Axis PTZ")
            MarkerView(symbol: "dot.radiowaves.left.and.right", headingDegrees: 200,
                       kind: .reported, tint: .orange,
                       activity: .stale, label: "Kraken")
            MarkerView(symbol: "cloud.sun.fill", headingDegrees: nil,
                       kind: .deployed, tint: .teal, activity: .offline, label: "Tempest")
        }
        HStack(spacing: 28) {
            MarkerView(symbol: "location.north.line.fill", headingDegrees: 310,
                       tint: .blue, label: "367123456", isSelected: true)
            MarkerView(symbol: "shippingbox", headingDegrees: nil,
                       tint: .secondary, activity: .offline, label: "no label",
                       showsLabel: false)
        }
    }
    .padding(40)
    .background(Color(.systemGroupedBackground))
}
