import SwiftUI

// MARK: - HeadingMarker
//
// A system's glyph on the map, turned to face the way it is facing.
//
// Rotation is map-north-up: the map is not rotated, so a heading in degrees
// clockwise from north is a rotation of the same number of degrees. When there
// is no heading the glyph is drawn plain rather than pointing north, because a
// marker that always points north reads as a claim and is a guess.

struct HeadingMarker: View {

    let symbol: String
    /// Degrees clockwise from true north, or nil when nothing says.
    let headingDegrees: Double?
    var kind: RemoteSystem.PositionKind = .live
    var tint: Color = .accentColor
    var size: CGFloat = 26

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            glyph
            if kind == .reported {
                // The badge distinguishes "this system says where it is" from
                // "this system is being tracked", which are different levels of
                // evidence for the same pin.
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(2)
                    .background(tint, in: Circle())
                    .offset(x: size * 0.22, y: size * 0.22)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var glyph: some View {
        let circle = Circle()
            .fill(kind == .deployed ? tint.opacity(0.55) : tint)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(radius: 2)

        // A deployed marker never rotates: the system resource carries a point,
        // not an attitude, and spinning it would invent one.
        if kind != .deployed, let headingDegrees {
            circle.rotationEffect(.degrees(headingDegrees))
        } else {
            circle
        }
    }

    private var accessibilityLabel: String {
        var parts = [kindDescription]
        if kind != .deployed, let headingDegrees {
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
    HStack(spacing: 24) {
        HeadingMarker(symbol: "location.north.line.fill", headingDegrees: 45)
        HeadingMarker(symbol: "dot.radiowaves.left.and.right",
                      headingDegrees: 120, kind: .reported, tint: .orange)
        HeadingMarker(symbol: "cloud.sun.fill", headingDegrees: nil,
                      kind: .deployed, tint: .teal)
    }
    .padding()
}
