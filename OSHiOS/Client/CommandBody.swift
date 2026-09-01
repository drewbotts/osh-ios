import Foundation

// MARK: - CommandBody
//
// Building the JSON a command is sent as, one ordered string at a time.
//
// Split out from CommandClient so it can be tested without a node and read
// without a network. Everything here is deliberately unglamorous — no
// JSONEncoder, no dictionaries — because the node's parser walks a command in
// the order its schema declares and a Dictionary would reorder the one thing
// that must not be reordered. The same discipline ConnectedSystemsClient uses
// for observations, for the same reason.

// MARK: - CommandValue

/// A value a command parameter can carry.
///
/// Three cases because the reference camera's DataChoice has exactly three
/// kinds of item: a Quantity (`rpan`), a Text (`preset`) and a DataRecord
/// (`ptzPos`). A schema offering something else gets the read-only parameter
/// tree until there is a real command to build for it.
enum CommandValue: Sendable, Equatable {
    case number(Double)
    case text(String)
    /// Fields in the order the schema declares them. Order is load-bearing.
    case record([CommandField])
}

/// One named field inside a `.record`.
struct CommandField: Sendable, Equatable {
    let name: String
    let value: CommandValue

    init(_ name: String, _ value: CommandValue) {
        self.name = name
        self.value = value
    }
}

// MARK: - CommandBody

enum CommandBody {

    /// The full request body for a DataChoice command.
    ///
    /// Verified against the reference node (see COMMANDS.md):
    ///
    ///     {"parameters":{"rpan":3.0}}
    ///
    /// A DataChoice selects exactly one item, and on the wire the selection is
    /// the sole key of the parameters object — which is why this takes one item
    /// name rather than a dictionary of them.
    ///
    /// - Parameter issueTime: emitted before `parameters` when given. The node
    ///   accepts the command with or without it; it is offered because a client
    ///   that queues a move while offline will need to say when it meant it.
    static func choice(item: String,
                       value: CommandValue,
                       issueTime: Date? = nil) -> String {
        var body = "{"
        if let issueTime {
            body += "\"issueTime\":\(string(issueTime.iso8601Millis)),"
        }
        body += "\"parameters\":\(parameters(item: item, value: value))}"
        return body
    }

    /// Just the parameters object — `{"rpan":3.0}` — for a caller assembling
    /// its own envelope, and the unit under test.
    static func parameters(item: String, value: CommandValue) -> String {
        object([CommandField(item, value)])
    }

    // MARK: Primitives

    static func object(_ fields: [CommandField]) -> String {
        "{" + fields.map { "\(string($0.name)):\(encode($0.value))" }
            .joined(separator: ",") + "}"
    }

    static func encode(_ value: CommandValue) -> String {
        switch value {
        case .number(let number): return self.number(number)
        case .text(let text):     return string(text)
        case .record(let fields): return object(fields)
        }
    }

    /// A JSON number.
    ///
    /// Whole values keep a ".0" — `3.0`, not `3`. Not required by JSON, but it
    /// is what the node echoes back in its own command listing, and matching it
    /// keeps a captured request and a captured response comparable by eye.
    /// A non-finite value would serialise as `nan` or `inf`, neither of which
    /// is JSON, so it becomes 0 rather than an unparseable body.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0.0" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(format: "%.1f", value)
        }
        return String(value)
    }

    /// A JSON string with the six escapes the grammar requires.
    static func string(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count + 2)
        for character in text.unicodeScalars {
            switch character {
            case "\"":  escaped += "\\\""
            case "\\":  escaped += "\\\\"
            case "\n":  escaped += "\\n"
            case "\r":  escaped += "\\r"
            case "\t":  escaped += "\\t"
            default:
                if character.value < 0x20 {
                    escaped += String(format: "\\u%04x", character.value)
                } else {
                    escaped.unicodeScalars.append(character)
                }
            }
        }
        return "\"\(escaped)\""
    }
}

// MARK: - Date

private extension Date {
    /// The spelling the node uses for its own issueTime.
    var iso8601Millis: String {
        CommandBody.isoFormatter.string(from: self)
    }
}

extension CommandBody {
    /// nonisolated(unsafe): configured once, never mutated, and Foundation
    /// documents string(from:) as safe for concurrent use.
    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
