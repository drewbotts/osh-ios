import Testing
import Foundation
@testable import osh_ios

// MARK: - PTZHomePlanTests
//
// The home command, from the two real control schemas on the reference node.

@Suite("PTZ home plan")
struct PTZHomePlanTests {

    private func capability(_ slug: FixtureLoader.Slug) throws -> PTZCapability {
        let data = try FixtureLoader.requiredData(slug, "control-schema.json")
        let schema = try SWESchemaDecoder.decode(data)
        return try #require(PTZCapability.detect(in: schema.recordSchema, controlStreamId: "cs"))
    }

    @Test("The Axis camera goes home with one ptzPos record at pan 0, tilt 0, zoom 1")
    func axisUsesPositionRecord() throws {
        let plan = try #require(PTZHomePlan.plan(for: try capability(.choicePTZControl)))
        #expect(plan.controlStreamId == "cs")
        #expect(!plan.isGuess)
        #expect(plan.steps.count == 1)
        let step = plan.steps[0]
        #expect(step.item == "ptzPos")
        // The body the node would receive, in schema order — the same string
        // CommandBodyTests pins for an absolute move.
        #expect(CommandBody.choice(item: step.item, value: step.value)
                == #"{"parameters":{"ptzPos":{"pan":0.0,"tilt":0.0,"zoom":1.0}}}"#)
    }

    @Test("The DR-CAMERA goes home with its Reset preset")
    func namedCameraUsesResetPreset() throws {
        let plan = try #require(PTZHomePlan.plan(for: try capability(.namedPTZControl)))
        #expect(!plan.isGuess)
        #expect(plan.steps == [PTZHomePlan.Step(item: "preset", value: .text("Reset"))])
    }

    @Test("Separate absolute axes become two commands")
    func separateAxes() throws {
        let capability = PTZCapability(controlStreamId: "cs",
                                       absolutePan: .init(itemName: "pan", range: -170...170),
                                       absoluteTilt: .init(itemName: "tilt", range: -90...0))
        let plan = try #require(PTZHomePlan.plan(for: capability))
        #expect(plan.steps == [PTZHomePlan.Step(item: "pan", value: .number(0)),
                               PTZHomePlan.Step(item: "tilt", value: .number(0))])
    }

    @Test("Zero is clamped into the axis range")
    func clampsToRange() throws {
        let record = PTZCapability.PositionRecord(itemName: "ptzPos",
                                                  pan: .init(itemName: "pan", range: 10...20),
                                                  tilt: .init(itemName: "tilt", range: -45...(-5)),
                                                  zoom: .init(itemName: "zoom", range: 2...8))
        let plan = try #require(PTZHomePlan.plan(for: PTZCapability(controlStreamId: "cs", position: record)))
        #expect(plan.steps[0].value == .record([CommandField("pan", .number(10)),
                                                CommandField("tilt", .number(-5)),
                                                CommandField("zoom", .number(2))]))
    }

    @Test("An open preset field guesses \"Home\" and says so")
    func openPresetGuessesHome() throws {
        let capability = PTZCapability(controlStreamId: "cs",
                                       relativePan: .init(itemName: "rpan"),
                                       relativeTilt: .init(itemName: "rtilt"),
                                       preset: .init(itemName: "preset"))
        let plan = try #require(PTZHomePlan.plan(for: capability))
        #expect(plan.isGuess)
        #expect(plan.steps == [PTZHomePlan.Step(item: "preset", value: .text("Home"))])
    }

    @Test("A closed preset list with nothing meaning home yields no plan")
    func closedPresetWithoutHome() {
        let capability = PTZCapability(controlStreamId: "cs",
                                       relativePan: .init(itemName: "rpan"),
                                       relativeTilt: .init(itemName: "rtilt"),
                                       preset: .init(itemName: "preset", tokens: ["Gate", "Lot"]))
        #expect(PTZHomePlan.plan(for: capability) == nil)
    }

    @Test("Relative-only cameras have no way home")
    func relativeOnly() {
        let capability = PTZCapability(controlStreamId: "cs",
                                       relativePan: .init(itemName: "rpan"),
                                       relativeTilt: .init(itemName: "rtilt"))
        #expect(PTZHomePlan.plan(for: capability) == nil)
    }
}
