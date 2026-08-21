import Foundation
import ActivityKit

// MARK: - SessionActivityController
//
// Drives the streaming Live Activity on the Lock Screen and in the Dynamic
// Island. All of ActivityKit's failure modes are non-fatal here: a device with
// Live Activities switched off, an unsupported device, or a system that refuses
// the request must never affect the streaming session, so every call is a
// no-op on failure and the reason is logged rather than surfaced.
//
// Updates are rate-limited. ActivityKit budgets frequent updates, and a session
// that ticks once a second would exhaust that budget within a minute — so the
// activity is refreshed only when connectivity changes, or every 30 s.

@MainActor
final class SessionActivityController {

    /// Minimum spacing between heartbeat refreshes.
    private static let heartbeatInterval: TimeInterval = 30

    private var activity: Activity<SessionActivityAttributes>?
    private var lastPushedAt: Date?
    private var lastConnected = true
    private var sensorCount = 0
    private var startedAt = Date()

    // MARK: Lifecycle

    func start(systemName: String, sensorCount: Int, startedAt: Date) {
        end()

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Log.session.info("Live Activities are disabled — skipping")
            return
        }

        self.sensorCount = sensorCount
        self.startedAt = startedAt
        self.lastConnected = true

        let attributes = SessionActivityAttributes(systemName: systemName)
        let state = SessionActivityAttributes.ContentState(
            stateLabel: "Streaming",
            sensorCount: sensorCount,
            startedAt: startedAt,
            isConnected: true)

        do {
            activity = try Activity.request(attributes: attributes,
                                            content: .init(state: state, staleDate: nil))
            lastPushedAt = Date()
            Log.session.info("Live Activity started for \(sensorCount) outputs")
        } catch {
            Log.session.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pushes immediately when connectivity flips — that is the one change a
    /// glance at the Lock Screen has to be right about.
    func update(isConnected: Bool) {
        guard activity != nil, isConnected != lastConnected else { return }
        lastConnected = isConnected
        push(isConnected: isConnected)
    }

    /// Called from the session's 1 s tick; forwards at most once per interval.
    func heartbeat(isConnected: Bool) {
        guard activity != nil else { return }
        if let lastPushedAt, Date().timeIntervalSince(lastPushedAt) < Self.heartbeatInterval {
            return
        }
        lastConnected = isConnected
        push(isConnected: isConnected)
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastPushedAt = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    // MARK: Private

    private func push(isConnected: Bool) {
        guard let activity else { return }
        let state = SessionActivityAttributes.ContentState(
            stateLabel: isConnected ? "Streaming" : "Buffering",
            sensorCount: sensorCount,
            startedAt: startedAt,
            isConnected: isConnected)
        lastPushedAt = Date()
        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }
}
