import SwiftUI

// MARK: - SurveyCompassView
//
// A full-size compass for the alignment screen: a fixed rose with north up, a
// large arrow for the phone's true heading, and behind it a shaded wedge as
// wide as the compass's own accuracy figure. The wedge is the point — a 3°
// arrow inside a 40° wedge tells the user, before any number does, that the
// magnetometer is being pulled about by the mount they are standing next to.
//
// Drawn in a Canvas like HeadingDialView, and not built from it: that dial is
// sized for a card, and a rose with numbered ticks and an accuracy wedge is a
// different drawing rather than a bigger one.

struct SurveyCompassView: View {

    /// Degrees clockwise from true north. nil draws the rose alone.
    let headingDegrees: Double?
    /// ± degrees of heading uncertainty, or nil when unknown.
    var accuracyDegrees: Double?
    var tint: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2 - 18
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)

            // Accuracy wedge first, so the arrow sits on top of it.
            if let headingDegrees, let accuracyDegrees, accuracyDegrees > 0 {
                let half = min(accuracyDegrees, 180)
                var wedge = Path()
                wedge.move(to: centre)
                wedge.addArc(center: centre, radius: radius - 6,
                             startAngle: .degrees(headingDegrees - half - 90),
                             endAngle: .degrees(headingDegrees + half - 90),
                             clockwise: false)
                wedge.closeSubpath()
                context.fill(wedge, with: .color(tint.opacity(0.14)))
            }

            // Rose.
            context.stroke(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                                  width: radius * 2, height: radius * 2)),
                           with: .color(.secondary.opacity(0.4)), lineWidth: 1.5)

            for degrees in stride(from: 0, to: 360, by: 10) {
                let isCardinal = degrees % 90 == 0
                let isMajor = degrees % 30 == 0
                let inner = radius - (isCardinal ? 16 : isMajor ? 11 : 6)
                var tick = Path()
                tick.move(to: point(centre, inner, Double(degrees)))
                tick.addLine(to: point(centre, radius, Double(degrees)))
                context.stroke(tick,
                               with: .color(degrees == 0 ? .red : .secondary.opacity(isMajor ? 0.8 : 0.4)),
                               lineWidth: isCardinal ? 2.5 : isMajor ? 1.5 : 1)
            }

            for (label, degrees) in [("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)] {
                let position = point(centre, radius + 11, degrees)
                context.draw(Text(label)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundColor(label == "N" ? .red : .secondary),
                             at: position)
            }

            // Arrow.
            guard let headingDegrees else {
                context.fill(Path(ellipseIn: CGRect(x: centre.x - 4, y: centre.y - 4, width: 8, height: 8)),
                             with: .color(.secondary))
                return
            }
            let tip = point(centre, radius - 22, headingDegrees)
            let tail = point(centre, radius * 0.28, headingDegrees + 180)
            let leftWing = point(centre, radius * 0.30, headingDegrees + 150)
            let rightWing = point(centre, radius * 0.30, headingDegrees - 150)
            var arrow = Path()
            arrow.move(to: tip)
            arrow.addLine(to: leftWing)
            arrow.addLine(to: tail)
            arrow.addLine(to: rightWing)
            arrow.closeSubpath()
            context.fill(arrow, with: .color(tint))
            context.stroke(arrow, with: .color(tint.opacity(0.6)), lineWidth: 1)
            context.fill(Path(ellipseIn: CGRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10)),
                         with: .color(Color(.systemBackground)))
        }
        .accessibilityLabel(headingDegrees.map { String(format: "heading %.0f degrees true", $0) }
                            ?? "no heading")
    }

    /// Compass degrees to a point: 0° up, clockwise.
    private func point(_ centre: CGPoint, _ radius: Double, _ degrees: Double) -> CGPoint {
        let radians = (degrees - 90) * .pi / 180
        return CGPoint(x: centre.x + radius * cos(radians), y: centre.y + radius * sin(radians))
    }
}

#Preview {
    VStack {
        SurveyCompassView(headingDegrees: 217.5, accuracyDegrees: 25)
            .frame(width: 280, height: 280)
        SurveyCompassView(headingDegrees: nil)
            .frame(width: 160, height: 160)
    }
    .padding()
}
