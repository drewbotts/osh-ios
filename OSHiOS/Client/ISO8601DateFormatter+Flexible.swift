import Foundation

// MARK: - Flexible ISO 8601 parsing
//
// A node emits both spellings of the same instant — with fractional seconds on
// observations, without them on some resource metadata — and an
// ISO8601DateFormatter configured for one refuses the other outright. Every
// timestamp the app reads back therefore goes through here.
//
// Lived in the map model until activity states needed it too; it is node
// wire-format handling, not drawing.

extension ISO8601DateFormatter {

    /// nonisolated(unsafe): formatOptions are set once and never mutated, and
    /// Foundation documents date(from:) as safe for concurrent use.
    nonisolated(unsafe) static let flexible: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: String) -> Date? {
        flexible.date(from: text) ?? plain.date(from: text)
    }
}
