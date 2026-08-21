import SwiftUI

// MARK: - SessionBar
//
// The one place the session is controlled from: current state, elapsed time,
// network health, and a single primary button whose meaning follows the state
// machine (Start / Cancel / Stop, plus Retry and Dismiss after a failure).
//
// A single button rather than a row of them: at any moment exactly one action
// is meaningful, and offering the others greyed out only invites the question
// of why they are there.

struct SessionBar: View {

    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var connections: NodeConnectionStore
    @EnvironmentObject private var session: SensorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow

            if case .failed(let error) = session.state {
                failureDetail(for: error)
            }

            controls
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Status

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if case .connecting = session.state {
                ProgressView()
                    .controlSize(.small)
            } else {
                Circle()
                    .fill(stateColor)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
            }

            Text(stateLabel)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if case .streaming = session.state, let start = session.sessionStart {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Elapsed time")
            }
        }
        .accessibilityElement(children: .combine)
        // The network badge lives in `controls`, below, so a long connecting
        // message never squeezes it off the row.
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        if case .streaming = session.state, !session.isNetworkConnected {
            Label("Offline — \(session.queuedCount) buffered",
                  systemImage: "wifi.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.orange)
        }

        switch session.state {
        case .idle:
            Button("Start Streaming", action: startSession)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(connections.active == nil)

            if connections.active == nil {
                Text("Select a server on the Node tab to start.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .connecting:
            Button("Cancel", role: .cancel) { session.cancelStartup() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

        case .streaming:
            Button("Stop Streaming", role: .destructive) { session.stop() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

        case .failed:
            HStack(spacing: 12) {
                Button("Retry", action: startSession)
                    .buttonStyle(.borderedProminent)
                    .disabled(connections.active == nil)
                Button("Dismiss") { session.dismissError() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func failureDetail(for error: Error) -> some View {
        let message = SensorSession.userFacingMessage(for: error)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.title)
                    .font(.subheadline.weight(.semibold))
                Text(message.suggestion)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    private func startSession() {
        guard let connection = connections.active else { return }
        session.start(config: settings.config,
                      connection: connection,
                      systemName: settings.systemName)
    }

    // MARK: Presentation

    private var stateLabel: String {
        switch session.state {
        case .idle:                return "Idle"
        case .connecting(let step): return step
        case .streaming:           return "Streaming"
        case .failed:              return "Failed"
        }
    }

    private var stateColor: Color {
        switch session.state {
        case .idle:       return .secondary
        case .connecting: return .orange
        case .streaming:  return session.isNetworkConnected ? .green : .orange
        case .failed:     return .red
        }
    }
}

#Preview("Idle") {
    SessionBar()
        .padding()
        .previewEnvironment()
}
