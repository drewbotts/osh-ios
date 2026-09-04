import Testing
import Foundation
@testable import osh_ios

// MARK: - PTZCapabilityTests
//
// Recognising a camera from its command schema, checked against the real thing:
// choice-ptz-control is the Axis PTZ control stream on the reference node,
// captured byte for byte. If the app can drive that camera, the assertions here
// are why.

@Suite("PTZ capability")
struct PTZCapabilityTests {

    // MARK: Fixture

    private static func fixtureSchema() throws -> DataRecord {
        let data = try FixtureLoader.requiredData(.choicePTZControl, "control-schema.json")
        return try SWESchemaDecoder.decode(data).recordSchema
    }

    private static func fixtureCapability() throws -> PTZCapability {
        try #require(PTZCapability.detect(in: try fixtureSchema(),
                                          controlStreamId: "025svjetu8qg"))
    }

    // MARK: Detection

    @Test("The Axis PTZ control stream is recognised")
    func detectsFixture() throws {
        let capability = try Self.fixtureCapability()
        #expect(capability.controlStreamId == "025svjetu8qg")
        #expect(capability.supportsDPad)
        #expect(capability.supportsAbsolute)
    }

    /// The schema wraps its DataChoice in a single-field record — that is what
    /// SWESchemaDecoder does with a non-record root — so detection has to see
    /// through the wrapper, and this is the assertion that says it does.
    @Test("Detection sees through the decoder's record wrapper")
    func seesThroughWrapper() throws {
        let record = try Self.fixtureSchema()
        #expect(record.fields.count == 1)
        #expect(record.fields[0].component is SWEDataChoice)
        #expect(PTZCapability.dataChoice(in: record) != nil)
    }

    @Test("All eight choice items land on the right axis")
    func everyItemMaps() throws {
        let capability = try Self.fixtureCapability()

        #expect(capability.relativePan?.itemName == "rpan")
        #expect(capability.relativeTilt?.itemName == "rtilt")
        #expect(capability.relativeZoom?.itemName == "rzoom")
        #expect(capability.absolutePan?.itemName == "pan")
        #expect(capability.absoluteTilt?.itemName == "tilt")
        #expect(capability.absoluteZoom?.itemName == "zoom")
        #expect(capability.preset?.itemName == "preset")
        #expect(capability.position?.itemName == "ptzPos")
    }

    /// "RelativePan" contains "Pan", so an implementation that tested the
    /// absolute rules first would swallow every relative axis and offer a D-pad
    /// that issued absolute moves.
    @Test("A relative axis is never mistaken for its absolute namesake")
    func relativeBeatsAbsolute() throws {
        let capability = try Self.fixtureCapability()
        #expect(capability.relativePan?.itemName != capability.absolutePan?.itemName)
        #expect(capability.relativeTilt?.itemName != capability.absoluteTilt?.itemName)
        #expect(capability.relativeZoom?.itemName != capability.absoluteZoom?.itemName)
    }

    // MARK: Ranges

    @Test("Absolute ranges come from the schema's AllowedValues intervals")
    func ranges() throws {
        let capability = try Self.fixtureCapability()

        #expect(capability.absolutePan?.range == -180...180)
        #expect(capability.absoluteTilt?.range == -90...0)
        #expect(capability.absoluteZoom?.range == 1...9999)
    }

    @Test("The relative axes declare no range, and none is invented")
    func relativeAxesAreUnbounded() throws {
        let capability = try Self.fixtureCapability()

        #expect(capability.relativePan?.range == nil)
        #expect(capability.relativeTilt?.range == nil)
        #expect(capability.relativeZoom?.range == nil)
    }

    @Test("The ptzPos record carries its own three ranges")
    func positionRecordRanges() throws {
        let position = try #require(try Self.fixtureCapability().position)

        #expect(position.pan.itemName == "pan")
        #expect(position.tilt.itemName == "tilt")
        #expect(position.zoom.itemName == "zoom")
        #expect(position.pan.range == -180...180)
        #expect(position.tilt.range == -90...0)
        #expect(position.zoom.range == 1...9999)
    }

    // MARK: Refusal

    /// The rule that keeps the app from drawing a joystick for a light switch.
    @Test("A choice with no pan/tilt pair is not a PTZ camera")
    func rejectsNonPTZ() {
        let choice = SWEDataChoice(
            definition: nil, label: nil, description: nil, choiceValue: nil,
            items: [
                DataField(name: "zoom",
                          component: Quantity(definition: "http://x/ZoomFactor",
                                              label: "Zoom", uom: "1")),
                DataField(name: "preset",
                          component: SWEText(definition: "http://x/CameraPresetPositionName",
                                             label: "Preset"))
            ])
        #expect(PTZCapability.detect(in: choice, controlStreamId: "c") == nil)
    }

    @Test("A record with no DataChoice at all is not a PTZ camera")
    func rejectsPlainRecord() {
        let record = DataRecord(definition: nil, label: nil, name: "settings",
                                fields: [DataField(name: "gain",
                                                   component: Quantity(uom: "dB"))])
        #expect(PTZCapability.detect(in: record, controlStreamId: "c") == nil)
    }

    /// Relative-only is enough on its own: a camera that can be nudged but not
    /// aimed still deserves a D-pad.
    @Test("A relative-only choice is a PTZ camera without an absolute panel")
    func relativeOnly() {
        let choice = SWEDataChoice(
            definition: nil, label: nil, description: nil, choiceValue: nil,
            items: [
                DataField(name: "rpan",
                          component: Quantity(definition: "http://x/RelativePan", uom: "deg")),
                DataField(name: "rtilt",
                          component: Quantity(definition: "http://x/RelativeTilt", uom: "deg"))
            ])
        let capability = PTZCapability.detect(in: choice, controlStreamId: "c")
        #expect(capability?.supportsDPad == true)
        #expect(capability?.supportsAbsolute == false)
    }

    // MARK: Named moves

    private static func namedFixtureCapability() throws -> PTZCapability {
        let data = try FixtureLoader.requiredData(.namedPTZControl, "control-schema.json")
        let schema = try SWESchemaDecoder.decode(data).recordSchema
        return try #require(PTZCapability.detect(in: schema, controlStreamId: "03fdhisrs8s0"))
    }

    /// The second camera on the reference node: no Quantity anywhere, two Text
    /// items with token lists. It is a PTZ camera because "Up", "Down", "Left"
    /// and "Right" are all there — and the pad drives it with names.
    @Test("A camera that moves by direction name is recognised")
    func detectsNamedMoves() throws {
        let capability = try Self.namedFixtureCapability()

        #expect(capability.supportsDPad)
        #expect(!capability.supportsQuantityDPad)
        #expect(!capability.supportsAbsolute)
        #expect(capability.relativePan == nil)
        #expect(capability.relativeTilt == nil)

        let moves = try #require(capability.namedMoves)
        #expect(moves.itemName == "relMove")
        #expect(moves.supportsDPad)
        #expect(moves.hasDiagonals)
    }

    @Test("Every token keeps the camera's own spelling")
    func namedMoveTokens() throws {
        let moves = try #require(try Self.namedFixtureCapability().namedMoves)

        #expect(moves.token(for: .up) == "Up")
        #expect(moves.token(for: .down) == "Down")
        #expect(moves.token(for: .left) == "Left")
        #expect(moves.token(for: .right) == "Right")
        #expect(moves.token(for: .upLeft) == "TopLeft")
        #expect(moves.token(for: .upRight) == "TopRight")
        #expect(moves.token(for: .downLeft) == "BottomLeft")
        #expect(moves.token(for: .downRight) == "BottomRight")
    }

    /// The preset on this camera lists its names, so the overlay can offer a
    /// menu rather than a field. The Axis one does not, and must not grow a
    /// token list from nowhere.
    @Test("Preset tokens are carried when the schema lists them, and only then")
    func presetTokens() throws {
        let named = try Self.namedFixtureCapability()
        #expect(named.preset?.itemName == "preset")
        #expect(named.preset?.tokens == ["Reset", "TopMost", "BottomMost", "LeftMost", "RightMost"])

        let axis = try Self.fixtureCapability()
        #expect(axis.preset?.itemName == "preset")
        #expect(axis.preset?.tokens == nil)
        #expect(axis.namedMoves == nil)
    }

    @Test("Direction words are read in any casing or joining")
    func directionSpellings() {
        let text = SWEText(definition: "http://x/CameraRelativeMovementName",
                           label: nil,
                           constraint: AllowedTokens(values: ["UP", "down", "left", "RIGHT",
                                                              "up-left", "BOTTOM_RIGHT", "Stop"]))
        let moves = PTZCapability.namedMoves(named: "move", text: text)
        #expect(moves?.token(for: .up) == "UP")
        #expect(moves?.token(for: .downRight) == "BOTTOM_RIGHT")
        #expect(moves?.token(for: .upLeft) == "up-left")
        #expect(moves?.token(for: .downLeft) == nil)
        #expect(moves?.supportsDPad == true)
    }

    /// Two rules, both needed. A Text called "mode" with direction-like tokens
    /// is not a move; a Text defined as a movement with no token list gives
    /// the app nothing it could send.
    @Test("A named-move item needs both a movement definition and direction tokens")
    func namedMovesNeedBothSignals() {
        let wrongDefinition = SWEText(definition: "http://x/OperatingMode",
                                      label: nil,
                                      constraint: AllowedTokens(values: ["Up", "Down", "Left", "Right"]))
        #expect(PTZCapability.namedMoves(named: "mode", text: wrongDefinition) == nil)

        let noTokens = SWEText(definition: "http://x/CameraRelativeMovementName", label: nil)
        #expect(PTZCapability.namedMoves(named: "relMove", text: noTokens) == nil)

        let notDirections = SWEText(definition: "http://x/CameraRelativeMovementName",
                                    label: nil,
                                    constraint: AllowedTokens(values: ["Fast", "Slow"]))
        #expect(PTZCapability.namedMoves(named: "relMove", text: notDirections) == nil)
    }

    /// Left and Right alone is a panner. Without Up and Down there is no pad,
    /// and with nothing else on the choice there is no PTZ camera.
    @Test("Named moves without all four cardinal directions do not make a PTZ camera")
    func namedMovesNeedFourDirections() {
        let choice = SWEDataChoice(
            definition: nil, label: nil, description: nil, choiceValue: nil,
            items: [
                DataField(name: "relMove",
                          component: SWEText(definition: "http://x/CameraRelativeMovementName",
                                             label: nil,
                                             constraint: AllowedTokens(values: ["Left", "Right"])))
            ])
        #expect(PTZCapability.detect(in: choice, controlStreamId: "c") == nil)
    }

    /// Definitions before names, but names when there is no definition — which
    /// is how a driver that only spells its items survives.
    @Test("Bare item names are recognised when nothing defines them")
    func namesWithoutDefinitions() {
        let choice = SWEDataChoice(
            definition: nil, label: nil, description: nil, choiceValue: nil,
            items: [
                DataField(name: "rpan", component: Quantity(uom: "deg")),
                DataField(name: "rtilt", component: Quantity(uom: "deg")),
                DataField(name: "rzoom", component: Quantity(uom: "1"))
            ])
        let capability = PTZCapability.detect(in: choice, controlStreamId: "c")
        #expect(capability?.relativePan?.itemName == "rpan")
        #expect(capability?.relativeZoom?.itemName == "rzoom")
        #expect(capability?.supportsDPad == true)
    }
}
