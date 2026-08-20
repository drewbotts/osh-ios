import Foundation
import os

// MARK: - Log
//
// Central os.Logger instances for the app. Unified logging (rather than print)
// gives us levels, subsystem/category filtering in Console.app and `log stream`,
// and no stdout cost in Release builds.
//
// Filter a running device or simulator with:
//   log stream --predicate 'subsystem == "org.opensensorhub.oshios"'

enum Log {
    private static let subsystem = "org.opensensorhub.oshios"

    /// Connected Systems HTTP client, registration and observation posting.
    static let api = Logger(subsystem: subsystem, category: "api")

    /// Camera capture and H.264 encoding.
    static let video = Logger(subsystem: subsystem, category: "video")

    /// GPS, orientation, barometer and audio-level sensor outputs.
    static let sensors = Logger(subsystem: subsystem, category: "sensors")

    /// SensorSession lifecycle and state transitions.
    static let session = Logger(subsystem: subsystem, category: "session")
}
