import Foundation
import ActivityKit

// MARK: - SessionActivityAttributes
//
// The contract between the app and the OSHiOSWidgets extension for the
// streaming Live Activity. It lives in its own folder because both targets
// compile it: the app starts and updates the activity, the widget renders it,
// and ActivityKit matches the two by this type.
//
// Keep it small and free of app types — everything here is copied into the
// system's activity store on every update.

struct SessionActivityAttributes: ActivityAttributes {

    /// Fixed for the life of the activity: the name this device publishes under.
    let systemName: String

    struct ContentState: Codable, Hashable {
        /// Short status word shown on the Lock Screen, e.g. "Streaming".
        var stateLabel: String
        /// Number of outputs currently streaming.
        var sensorCount: Int
        /// When streaming began — drives Text(timerInterval:).
        var startedAt: Date
        /// False while observations are buffering locally.
        var isConnected: Bool
    }
}
