import SwiftUI

// MARK: - HeadingDialView
//
// A compass rose with one needle. Two cards use it, restyled rather than
// duplicated: an orientation card, where the needle is an arrow showing which
// way a device faces, and a bearing card, where it is a radial line running
// out to the rim toward a detected emitter.
//
// Drawn in a Canvas rather than as rotated views, because a dial is a handful
// of strokes and a Canvas draws them in one pass without a view per tick.

struct HeadingDialView: View {

    enum Needle {
        /// A device's facing: a short arrow from the centre.
        case arrow
        /// A line of bearing: a full radius, to the rim.
        case ray
    }

    /// Degrees clockwise from true north. nil draws the rose with no needle.
    let headingDegrees: Double?
    var needle: Needle = .arrow
    var tint: Color = .accentColor
    /// Dimmed when the reading is stale — an old LOB is still shown, faintly.
    var opacity: Double = 1

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2 - 2
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)

            context.stroke(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                                  width: radius * 2, height: radius * 2)),
                           with: .color(.secondary.opacity(0.35)),
                           lineWidth: 1)

            // Cardinal ticks, north long so the rose has an orientation even
            // when there is no needle to read it against.
            for degrees in stride(from: 0, to: 360, by: 30) {
                let isCardinal = degrees % 90 == 0
                let isNorth = degrees == 0
                let inner = radius - (isNorth ? 10 : isCardinal ? 7 : 4)
                context.stroke(
                    Path { path in
                        path.move(to: point(centre: centre, radius: inner, degrees: Double(degrees)))
                        path.addLine(to: point(centre: centre, radius: radius,
                                               degrees: Double(degrees)))
                    },
                    with: .color(isNorth ? .red.opacity(0.8) : .secondary.opacity(isCardinal ? 0.6 : 0.3)),
                    lineWidth: isNorth ? 2 : 1)
            }

            guard let headingDegrees else { return }

            switch needle {
            case .arrow:
                let tip = point(centre: centre, radius: radius - 12, degrees: headingDegrees)
                let leftWing = point(centre: centre, radius: radius * 0.35,
                                     degrees: headingDegrees + 140)
                let rightWing = point(centre: centre, radius: radius * 0.35,
                                      degrees: headingDegrees - 140)
                var path = Path()
                path.move(to: tip)
                path.addLine(to: leftWing)
                path.addLine(to: centre)
                path.addLine(to: rightWing)
                path.closeSubpath()
                context.fill(path, with: .color(tint.opacity(opacity)))

            case .ray:
                context.stroke(
                    Path { path in
                        path.move(to: centre)
                        path.addLine(to: point(centre: centre, radius: radius,
                                               degrees: headingDegrees))
                    },
                    with: .color(tint.opacity(opacity)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                context.fill(
                    Path(ellipseIn: CGRect(x: centre.x - 3, y: centre.y - 3,
                                           width: 6, height: 6)),
                    with: .color(tint.opacity(opacity)))
            }
        }
        .accessibilityLabel(headingDegrees.map { String(format: "%.0f degrees", $0) }
                            ?? "no reading")
    }

    /// Compass degrees to a point: 0° is up, and angles run clockwise, which is
    /// the opposite of the maths convention the trig functions use.
    private func point(centre: CGPoint, radius: Double, degrees: Double) -> CGPoint {
        let radians = (degrees - 90) * .pi / 180
        return CGPoint(x: centre.x + radius * cos(radians),
                       y: centre.y + radius * sin(radians))
    }
}

#Preview {
    HStack(spacing: 20) {
        HeadingDialView(headingDegrees: 42)
            .frame(width: 120, height: 120)
        HeadingDialView(headingDegrees: 217, needle: .ray, tint: .orange)
            .frame(width: 120, height: 120)
        HeadingDialView(headingDegrees: nil)
            .frame(width: 120, height: 120)
    }
    .padding()
}
