import Foundation

// MARK: - PTZHomePlan
//
// How to send a pan/tilt/zoom camera to its pan-zero reference before a survey.
//
// A surveyed orientation for a PTZ camera has to describe the *mount*, not
// wherever the lens happened to be pointing: every pan and tilt the camera
// reports is relative to that base frame, and slew-to-cue arithmetic inherits
// any error in it. The cleanest way to align a phone with the base frame is to
// put the camera there first and sight along the lens — which is what this
// plans, from the same PTZCapability the D-pad is built from.
//
// Absolute position is preferred over a preset because it is unambiguous: pan
// 0, tilt 0 *is* the base frame by definition, whereas a preset called "Home"
// is wherever somebody stored it.

struct PTZHomePlan: Equatable, Sendable {

    /// One command to send, in order.
    struct Step: Equatable, Sendable {
        let item: String
        let value: CommandValue
    }

    let controlStreamId: String
    let steps: [Step]
    /// What the button says it will do.
    let summary: String
    /// True when the plan rests on a naming convention rather than the schema
    /// — a preset called "Home" on a camera that lists no presets — so the UI
    /// can say "try" rather than "send".
    let isGuess: Bool

    /// The plan for a capability, or nil when the schema offers no way home.
    static func plan(for capability: PTZCapability) -> PTZHomePlan? {

        // 1. The combined absolute record: one move to (0, 0, wide).
        if let record = capability.position {
            let pan = clamp(0, to: record.pan.range)
            let tilt = clamp(0, to: record.tilt.range)
            let zoom = clamp(1, to: record.zoom.range)
            return PTZHomePlan(
                controlStreamId: capability.controlStreamId,
                steps: [Step(item: record.itemName, value: .record([
                    CommandField(record.pan.itemName, .number(pan)),
                    CommandField(record.tilt.itemName, .number(tilt)),
                    CommandField(record.zoom.itemName, .number(zoom))
                ]))],
                summary: String(format: "%@ → pan %g°, tilt %g°, zoom %g",
                                record.itemName, pan, tilt, zoom),
                isGuess: false)
        }

        // 2. Separate absolute axes: pan then tilt, two commands.
        if let pan = capability.absolutePan, let tilt = capability.absoluteTilt {
            return PTZHomePlan(
                controlStreamId: capability.controlStreamId,
                steps: [Step(item: pan.itemName, value: .number(clamp(0, to: pan.range))),
                        Step(item: tilt.itemName, value: .number(clamp(0, to: tilt.range)))],
                summary: "\(pan.itemName) 0°, then \(tilt.itemName) 0°",
                isGuess: false)
        }

        // 3. A preset the schema names as home or reset.
        if let preset = capability.preset {
            if let tokens = preset.tokens, !tokens.isEmpty {
                if let token = tokens.first(where: { Self.homeWords.contains($0.lowercased()) }) {
                    return PTZHomePlan(controlStreamId: capability.controlStreamId,
                                       steps: [Step(item: preset.itemName, value: .text(token))],
                                       summary: "\(preset.itemName) \"\(token)\"",
                                       isGuess: false)
                }
                // A closed vocabulary with nothing that means home: the app has
                // no business inventing a name the camera will refuse.
                return nil
            }
            // 4. An open preset field: "Home" is the name Axis cameras ship
            //    with, and the best available guess for any other.
            return PTZHomePlan(controlStreamId: capability.controlStreamId,
                               steps: [Step(item: preset.itemName, value: .text("Home"))],
                               summary: "\(preset.itemName) \"Home\"",
                               isGuess: true)
        }

        return nil
    }

    /// Preset names, lower-cased, that mean the base frame.
    static let homeWords: Set<String> = ["home", "reset", "default", "zero", "origin"]

    private static func clamp(_ value: Double, to range: ClosedRange<Double>?) -> Double {
        guard let range else { return value }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
