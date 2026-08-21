import Foundation
import os

// MARK: - LogPrivacy

/// Redaction marker for an interpolated value.
///
/// Deliberately mirrors os.log's spelling so `Log.api.info("… \(id, privacy:
/// .public)")` reads and compiles exactly as it did against os.Logger. The
/// difference is where redaction happens: OSHLogger renders the message itself
/// (so the Logs tab shows the same redacted text Console.app would), then hands
/// the finished string to os.Logger.
enum LogPrivacy: Sendable {
    case `public`
    case `private`
    case auto
}

// MARK: - LogMessage

/// A log message built from string interpolation, with the same privacy
/// annotations os.log accepts.
struct LogMessage: ExpressibleByStringInterpolation, CustomStringConvertible {

    let description: String

    init(stringLiteral value: String) {
        description = value
    }

    init(stringInterpolation: Interpolation) {
        description = stringInterpolation.text
    }

    struct Interpolation: StringInterpolationProtocol {
        var text: String

        init(literalCapacity: Int, interpolationCount: Int) {
            text = ""
            text.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        mutating func appendInterpolation(_ value: @autoclosure () -> String,
                                          privacy: LogPrivacy = .auto) {
            text += Self.render(value(), privacy: privacy)
        }

        mutating func appendInterpolation<T: BinaryInteger>(_ value: @autoclosure () -> T,
                                                            privacy: LogPrivacy = .auto) {
            text += Self.render(String(describing: value()), privacy: privacy)
        }

        mutating func appendInterpolation<T: BinaryFloatingPoint>(_ value: @autoclosure () -> T,
                                                                  privacy: LogPrivacy = .auto) {
            text += Self.render(String(describing: value()), privacy: privacy)
        }

        mutating func appendInterpolation(_ value: @autoclosure () -> Bool,
                                          privacy: LogPrivacy = .auto) {
            text += Self.render(value() ? "true" : "false", privacy: privacy)
        }

        /// Numbers and other non-string values default to visible, matching
        /// os.log; only strings are redacted unless marked otherwise. Nothing
        /// in this app logs user data, so `.auto` is visible throughout.
        private static func render(_ string: String, privacy: LogPrivacy) -> String {
            privacy == .private ? "<private>" : string
        }
    }
}

// MARK: - OSHLogger
//
// One logging category, written to two places at once: the unified log (for
// Console.app and `log stream`) and LogStore (for the Logs tab). Call sites are
// unchanged from plain os.Logger — same method names, same interpolation.

struct OSHLogger: Sendable {

    private let logger: Logger
    private let subsystem: String
    private let category: String

    init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    func debug(_ message: LogMessage)   { emit(.debug,   message) }
    func info(_ message: LogMessage)    { emit(.info,    message) }
    func notice(_ message: LogMessage)  { emit(.notice,  message) }
    func warning(_ message: LogMessage) { emit(.warning, message) }
    func error(_ message: LogMessage)   { emit(.error,   message) }
    func fault(_ message: LogMessage)   { emit(.fault,   message) }

    private func emit(_ level: LogLevel, _ message: LogMessage) {
        let text = message.description
        // Already redacted above, so the unified log takes the finished string.
        switch level {
        case .debug:   logger.debug("\(text, privacy: .public)")
        case .info:    logger.info("\(text, privacy: .public)")
        case .notice:  logger.notice("\(text, privacy: .public)")
        case .warning: logger.warning("\(text, privacy: .public)")
        case .error:   logger.error("\(text, privacy: .public)")
        case .fault:   logger.fault("\(text, privacy: .public)")
        }
        LogStore.shared.record(level: level,
                               subsystem: subsystem,
                               category: category,
                               message: text)
    }
}
