import SwiftUI

// MARK: - ClusterMarkerView
//
// Several markers, drawn as one, with the count that says so.
//
// The bubble is a deliberately different shape from MarkerView: a plain filled
// circle with a number and a halo, no glyph and no heading. A cluster has no
// heading, and giving it the glyph of whichever member happened to sort first
// would be a claim about the group that only one member supports. The one thing
// it does keep is colour — when every member shares a tint the group is that
// colour, because a raft of AIS vessels is still a raft of vessels.
//
// It grows with the count, but slowly: the difference between six and sixty
// matters, the difference between six and seven does not, so the size follows
// the logarithm and the number carries the detail.

struct ClusterMarkerView: View {

    let count: Int
    var tint: Color = .accentColor
    var activity: ActivityState = .live
    var isSelected = false

    var body: some View {
        ZStack {
            // The halo is what reads as "there is more than one thing here" at
            // a glance, before the number is legible.
            Circle()
                .fill(tint.opacity(0.22))
                .frame(width: diameter * 1.38, height: diameter * 1.38)

            Circle()
                .fill(tint)
                .frame(width: diameter, height: diameter)
                .overlay {
                    Circle().strokeBorder(.white, lineWidth: isSelected ? 2.5 : 1.5)
                }
                .overlay {
                    Text(label)
                        .font(.system(size: diameter * 0.42, weight: .bold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(.white)
                        .padding(2)
                }
                .shadow(color: .black.opacity(0.28), radius: 2, y: 1)

            ActivityDot(state: activity, size: diameter * 0.26, ringColor: .white)
                .offset(x: diameter * 0.40, y: -diameter * 0.40)
        }
        .scaleEffect(isSelected ? 1.12 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) systems grouped here, \(activity.label)")
        .accessibilityHint("Opens the group")
    }

    /// 30pt for a pair, about 46 for a hundred. Logarithmic so a busy anchorage
    /// does not put a coin on the map.
    private var diameter: CGFloat {
        let growth = log2(Double(max(count, 2)))
        return min(30 + CGFloat(growth) * 3.4, 50)
    }

    /// Counts past two digits become "99+": a three-digit number inside a 50pt
    /// circle is unreadable, and "how many exactly" is what tapping is for.
    private var label: String { count > 99 ? "99+" : "\(count)" }
}

#Preview {
    HStack(spacing: 26) {
        ClusterMarkerView(count: 2, tint: .blue)
        ClusterMarkerView(count: 7, tint: .orange, activity: .stale)
        ClusterMarkerView(count: 41, tint: .secondary, activity: .offline)
        ClusterMarkerView(count: 350, tint: .blue, isSelected: true)
    }
    .padding(40)
    .background(Color(.systemGroupedBackground))
}
