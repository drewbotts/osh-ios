import Testing
import Foundation
@testable import osh_ios

// MARK: - CommandBodyTests
//
// The exact bytes of a command, because the node's parser is order-sensitive
// and a reordered record is a 400 rather than a best-effort move. Every
// expectation here is a string the reference node actually accepted — see
// OSHiOS/Client/COMMANDS.md for the captured exchanges.

@Suite("Command body")
struct CommandBodyTests {

    // MARK: Choice items

    @Test("A numeric choice item is the sole key of parameters")
    func numericChoiceItem() {
        #expect(CommandBody.choice(item: "rpan", value: .number(3))
                == #"{"parameters":{"rpan":3.0}}"#)
    }

    @Test("A negative relative move keeps its sign")
    func negativeNumber() {
        #expect(CommandBody.choice(item: "rpan", value: .number(-3))
                == #"{"parameters":{"rpan":-3.0}}"#)
    }

    @Test("A fractional value is not rounded to look tidy")
    func fractionalNumber() {
        #expect(CommandBody.parameters(item: "rzoom", value: .number(0.5))
                == #"{"rzoom":0.5}"#)
    }

    @Test("A text item is a JSON string")
    func textChoiceItem() {
        #expect(CommandBody.choice(item: "preset", value: .text("Home"))
                == #"{"parameters":{"preset":"Home"}}"#)
    }

    @Test("A preset name with a quote in it is escaped, not broken")
    func textEscaping() {
        #expect(CommandBody.parameters(item: "preset", value: .text("Gate \"A\"\n"))
                == #"{"preset":"Gate \"A\"\n"}"#)
    }

    // MARK: The record

    /// The case the whole ordered-string discipline exists for. The node reads
    /// ptzPos's fields in schema order and answers
    /// "Expected a name but was END_OBJECT" for anything else.
    @Test("ptzPos writes pan, tilt then zoom, in that order")
    func positionRecordIsOrdered() {
        let body = CommandBody.choice(item: "ptzPos", value: .record([
            CommandField("pan", .number(0)),
            CommandField("tilt", .number(-30)),
            CommandField("zoom", .number(1))
        ]))
        #expect(body == #"{"parameters":{"ptzPos":{"pan":0.0,"tilt":-30.0,"zoom":1.0}}}"#)
    }

    /// The same three fields in a different order must produce a different
    /// document — if this ever passes by accident, the ordering guarantee is
    /// gone and the node will start refusing absolute moves.
    @Test("Field order is preserved rather than normalised")
    func orderIsNotNormalised() {
        let reversed = CommandBody.parameters(item: "ptzPos", value: .record([
            CommandField("zoom", .number(1)),
            CommandField("tilt", .number(-30)),
            CommandField("pan", .number(0))
        ]))
        #expect(reversed == #"{"ptzPos":{"zoom":1.0,"tilt":-30.0,"pan":0.0}}"#)
    }

    // MARK: Envelope

    @Test("issueTime precedes parameters when it is given")
    func issueTimeComesFirst() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let body = CommandBody.choice(item: "rzoom", value: .number(0), issueTime: date)

        #expect(body.hasPrefix(#"{"issueTime":"#))
        #expect(body.contains(#","parameters":{"rzoom":0.0}}"#))
    }

    @Test("There is no control@id in the body — the URL identifies the stream")
    func noControlIdInBody() {
        #expect(!CommandBody.choice(item: "rpan", value: .number(1)).contains("control@id"))
    }

    // MARK: Numbers

    @Test("A non-finite value becomes 0.0 rather than unparseable JSON")
    func nonFiniteNumbers() {
        #expect(CommandBody.number(.nan) == "0.0")
        #expect(CommandBody.number(.infinity) == "0.0")
    }

    @Test("Whole numbers keep the .0 the node echoes back")
    func wholeNumbersKeepDecimal() {
        #expect(CommandBody.number(3) == "3.0")
        #expect(CommandBody.number(-90) == "-90.0")
        #expect(CommandBody.number(0) == "0.0")
    }
}
