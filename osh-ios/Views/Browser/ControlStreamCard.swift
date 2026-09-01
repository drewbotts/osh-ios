import SwiftUI

// MARK: - ControlStreamCard
//
// What a system will accept as a command, on its dashboard.
//
// Two outcomes, and the difference between them is the whole point of
// PTZCapability. A control stream the app recognised as a pan/tilt/zoom camera
// gets working controls. One it decoded but did not recognise gets its
// parameter tree, read-only, and says so — because "the app can read this and
// has not learned to drive it" and "the app could not read this" are different
// facts, and a user deciding whether to file a bug needs to know which.

struct ControlStreamCard: View {

    let controlStream: RemoteControlStream
    let connection: NodeConnection

    @StateObject private var controllerBox = ControllerBox()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let error = controlStream.schemaError {
                VStack(alignment: .leading, spacing: 4) {
                    Label("schema not understood", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let controller = controllerBox.controller {
                PTZControlView(controller: controller)
            } else if let schema = controlStream.paramsSchema {
                genericParameters(schema)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
        .onAppear { controllerBox.build(from: controlStream, connection: connection) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: controlStream.ptz != nil ? "dpad.fill" : "slider.horizontal.3")
                .font(.caption)
                .foregroundStyle(controlStream.ptz != nil ? Color.accentColor : Color.secondary)
            Text(controlStream.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 4)
            if controlStream.ptz != nil {
                Text("PTZ")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
            }
        }
    }

    // MARK: Generic

    /// The decoded parameters, read-only.
    ///
    /// A DataChoice is listed as its alternatives rather than as a record,
    /// because that is what it is: one of these, not all of them.
    @ViewBuilder
    private func genericParameters(_ schema: DataRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let choice = PTZCapability.dataChoice(in: schema) {
                Text("one of:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(Array(choice.items.enumerated()), id: \.offset) { _, item in
                    parameterRow(name: item.name, component: item.component)
                }
            } else {
                ForEach(Array(SchemaWalker.leaves(of: schema).enumerated()), id: \.offset) { _, leaf in
                    parameterRow(name: leaf.path.components.joined(separator: " / "),
                                 component: leaf.component)
                }
            }

            Label("command support for this structure not yet implemented",
                  systemImage: "wrench.and.screwdriver")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private func parameterRow(name: String, component: DataComponent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name)
                .font(.caption.monospaced())
            if let label = component.label, label != name {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let range = PTZCapability.range(of: component) {
                Text(String(format: "%g…%g", range.lowerBound, range.upperBound))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - ControllerBox

/// Holds the PTZController across body evaluations.
///
/// A @StateObject cannot be built from a value that is only known at `onAppear`
/// — the capability comes from the control stream, and the connection from the
/// environment — so the box is the state and the controller is its contents.
@MainActor
private final class ControllerBox: ObservableObject {

    @Published private(set) var controller: PTZController?

    func build(from controlStream: RemoteControlStream, connection: NodeConnection) {
        guard controller == nil, let capability = controlStream.ptz else { return }
        controller = PTZController(capability: capability, connection: connection)
    }
}
