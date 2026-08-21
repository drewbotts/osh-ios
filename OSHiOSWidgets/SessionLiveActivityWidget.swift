import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - SessionLiveActivityWidget
//
// Renders the streaming session on the Lock Screen and in the Dynamic Island.
//
// The elapsed time uses Text(timerInterval:) rather than a value pushed from
// the app: ActivityKit budgets updates, and a timer the system ticks itself
// costs nothing. The app therefore only pushes when connectivity changes or
// every 30 s — see SessionActivityController.
//
// No interactive controls. Stopping a session touches hardware and the network,
// which is not something to do from a Lock Screen button.

struct SessionLiveActivityWidget: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            lockScreenView(context)
                .activityBackgroundTint(Color.black.opacity(0.4))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.systemName)
                            .font(.caption)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "waveform.path.ecg")
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    connectionBadge(context.state)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        elapsed(context.state)
                            .font(.title3.monospacedDigit())
                        Spacer()
                        Text(sensorSummary(context.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(context.state.isConnected ? .green : .orange)
            } compactTrailing: {
                Text("\(context.state.sensorCount)")
                    .font(.caption.monospacedDigit())
            } minimal: {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(context.state.isConnected ? .green : .orange)
            }
        }
    }

    // MARK: Lock Screen

    private func lockScreenView(
        _ context: ActivityViewContext<SessionActivityAttributes>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.title2)
                .foregroundStyle(context.state.isConnected ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.systemName)
                    .font(.headline)
                    .lineLimit(1)
                Text(sensorSummary(context.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                elapsed(context.state)
                    .font(.title3.monospacedDigit())
                connectionBadge(context.state)
            }
        }
        .padding()
    }

    // MARK: Pieces

    private func elapsed(_ state: SessionActivityAttributes.ContentState) -> Text {
        Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
    }

    private func sensorSummary(_ state: SessionActivityAttributes.ContentState) -> String {
        "\(state.sensorCount) sensor\(state.sensorCount == 1 ? "" : "s") · \(state.stateLabel)"
    }

    private func connectionBadge(
        _ state: SessionActivityAttributes.ContentState
    ) -> some View {
        Text(state.isConnected ? "Connected" : "Buffering")
            .font(.caption2.weight(.medium))
            .foregroundStyle(state.isConnected ? .green : .orange)
    }
}
