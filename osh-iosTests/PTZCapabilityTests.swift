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
