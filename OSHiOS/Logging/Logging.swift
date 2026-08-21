import Foundation

// MARK: - Log
//
// Central loggers for the app. Each is an OSHLogger, which writes to the
// unified log *and* to LogStore so the Logs tab can show the same lines without
// OSLogStore (unreliable in-process, and gated on entitlements a normal install
// does not carry).
//
// Filter a running device or simulator with:
//   log stream --predicate 'subsystem == "org.opensensorhub.oshios"'

enum Log {
    static let subsystem = "org.opensensorhub.oshios"

    /// Every category, in the order the Logs tab lists them.
    static let categories = ["api", "video", "sensors", "session", "client"]

    /// Connected Systems HTTP client, registration and observation posting.
    static let api = OSHLogger(subsystem: subsystem, category: "api")

    /// Camera capture and H.264 encoding.
    static let video = OSHLogger(subsystem: subsystem, category: "video")

    /// GPS, orientation, barometer and audio-level sensor outputs.
    static let sensors = OSHLogger(subsystem: subsystem, category: "sensors")

    /// SensorSession lifecycle and state transitions.
    static let session = OSHLogger(subsystem: subsystem, category: "session")

    /// Read-side node access: connectivity checks, system and datastream browsing.
    static let client = OSHLogger(subsystem: subsystem, category: "client")
}
