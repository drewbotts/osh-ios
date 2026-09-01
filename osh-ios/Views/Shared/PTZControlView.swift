import SwiftUI

// MARK: - PTZController
//
// One camera's commands, serialised.
//
// The serialisation is the whole design. A D-pad auto-repeats while held, and a
// camera that is sent a move every 200 ms builds a queue it works through long
// after the finger comes off the button — the picture keeps drifting and the
// control feels broken. So there is never more than one command in flight, and
// a repeat that arrives while one is pending is dropped rather than queued. The
// user's finger and the camera's actual latency set the rate between them.

@MainActor
final class PTZController: ObservableObject {

    // MARK: Outcome

    /// What happened to the last command, for the transient badge.
    enum Outcome: Equatable {
        case success(status: String?)
        case failure(text: String)
    }

    // MARK: Configuration

    /// Auto-repeat: the pause before the second command, then the interval.
    static let repeatDelay: Duration = .milliseconds(400)
    static let repeatInterval: Duration = .milliseconds(500)

    /// How long an outcome badge stays up.
    static let outcomeLinger: Duration = .seconds(2)

    /// The three step sizes the segmented control offers.
    static let stepChoices: [Double] = [1, 5, 15]

    /// Relative zoom per press. Not a schema value — `rzoom` declares no range
    /// on the reference camera — so it is the app's judgement.
    static let zoomStep: Double = 0.5

    // MARK: State

    let capability: PTZCapability

    @Published private(set) var isSending = false
    @Published private(set) var outcome: Outcome?
    /// Set once on a 401/403. The overlay disables itself rather than letting a
    /// user press a dead button forty times.
    @Published private(set) var isForbidden = false

    private let client: CommandClient
    private var outcomeTask: Task<Void, Never>?

    // MARK: Init

    init(capability: PTZCapability, connection: NodeConnection) {
        self.capability = capability
        self.client = connection.commandClient
    }

    // MARK: Moves

    /// Relative pan. `sign` is −1 for left, +1 for right.
    func pan(_ sign: Double, step: Double) {
        guard let axis = capability.relativePan else { return }
        send(item: axis.itemName, value: .number(sign * step))
    }

    /// Relative tilt. `sign` is +1 for up, −1 for down.
    func tilt(_ sign: Double, step: Double) {
        guard let axis = capability.relativeTilt else { return }
        send(item: axis.itemName, value: .number(sign * step))
    }

    /// Relative zoom, or an absolute one when only absolute exists.
    func zoom(_ sign: Double) {
        if let axis = capability.relativeZoom {
            send(item: axis.itemName, value: .number(sign * Self.zoomStep))
        }
    }

    func setAbsoluteZoom(_ value: Double) {
        guard let axis = capability.absoluteZoom else { return }
        send(item: axis.itemName, value: .number(clamp(value, to: axis.range)))
    }

    func goToPreset(_ name: String) {
        guard let axis = capability.preset else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(item: axis.itemName, value: .text(trimmed))
    }

    /// The combined absolute move when the schema has one, three separate ones
    /// when it does not.
    ///
    /// The record is preferred because it is a single move: sending pan, then
    /// tilt, then zoom makes the camera perform three, and with only one command
    /// in flight at a time the user would watch it stagger through them.
    func goToPosition(pan: Double, tilt: Double, zoom: Double) {
        if let record = capability.position {
            send(item: record.itemName, value: .record([
                CommandField(record.pan.itemName, .number(clamp(pan, to: record.pan.range))),
                CommandField(record.tilt.itemName, .number(clamp(tilt, to: record.tilt.range))),
                CommandField(record.zoom.itemName, .number(clamp(zoom, to: record.zoom.range)))
            ]))
            return
        }
        if let axis = capability.absolutePan {
            send(item: axis.itemName, value: .number(clamp(pan, to: axis.range)))
        } else if let axis = capability.absoluteTilt {
            send(item: axis.itemName, value: .number(clamp(tilt, to: axis.range)))
        } else if let axis = capability.absoluteZoom {
            send(item: axis.itemName, value: .number(clamp(zoom, to: axis.range)))
        }
    }

    // MARK: Sending

    /// Issues one command, unless one is already in flight.
    ///
    /// - Returns: false when the command was dropped, which an auto-repeat
    ///   treats as "the camera is still busy" rather than as a failure.
    @discardableResult
    func send(item: String, value: CommandValue) -> Bool {
        guard !isSending, !isForbidden else { return false }
        isSending = true

        let json = CommandBody.choice(item: item, value: value)
        let controlStreamId = capability.controlStreamId
        let client = self.client

        Task { [weak self] in
            do {
                let receipt = try await client.sendCommand(controlStreamId: controlStreamId,
                                                           parameters: json)
                await MainActor.run { self?.finish(receipt, request: json) }
            } catch {
                Log.client.error("PTZ command \(json, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self?.finish(failure: error.localizedDescription)
                }
            }
        }
        return true
    }

    private func finish(_ receipt: CommandClient.CommandReceipt, request: String) {
        isSending = false

        if receipt.isSuccess {
            show(.success(status: receipt.reportedStatus))
            return
        }
        if receipt.isUnauthorized {
            isForbidden = true
            Log.client.error("Not authorized to control \(self.capability.controlStreamId, privacy: .public): HTTP \(receipt.statusCode) \(receipt.bodyText, privacy: .public)")
            show(.failure(text: "not authorized to control this camera"))
            return
        }
        // The node's message names the offending path — the Logs tab is where
        // an unfamiliar schema becomes diagnosable, so the body goes there
        // whole while the badge stays short.
        Log.client.error("PTZ command \(request, privacy: .public) → HTTP \(receipt.statusCode): \(receipt.bodyText, privacy: .public)")
        show(.failure(text: receipt.message ?? "HTTP \(receipt.statusCode)"))
    }

    private func finish(failure text: String) {
        isSending = false
        show(.failure(text: text))
    }

    private func show(_ result: Outcome) {
        outcome = result
        outcomeTask?.cancel()
        outcomeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.outcomeLinger)
            guard !Task.isCancelled else { return }
            self?.outcome = nil
        }
    }

    private func clamp(_ value: Double, to range: ClosedRange<Double>?) -> Double {
        guard let range else { return value }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: - PTZControlView

/// The controls themselves, meant to sit over a picture.
///
/// Everything is sized and spaced for a thumb over live video rather than for a
/// settings form: the pad is one block the hand can find without looking, and
/// the panels that need reading are behind a disclosure.
struct PTZControlView: View {

    @ObservedObject var controller: PTZController
    @EnvironmentObject private var settings: AppSettingsStore
    /// Called on any interaction, so the host can hold off its auto-hide.
    var onInteraction: () -> Void = {}

    @State private var presetName = ""
    @State private var showsAbsolute = false
    @State private var absolutePan: Double = 0
    @State private var absoluteTilt: Double = 0
    @State private var absoluteZoom: Double = 1

    private var capability: PTZCapability { controller.capability }
    private var step: Double { settings.config.ptzStepDegrees }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if controller.isForbidden {
                Label("Not authorized to control this camera", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                HStack(alignment: .center, spacing: 18) {
                    if capability.supportsDPad { dpad }
                    VStack(spacing: 10) {
                        if capability.relativeZoom != nil { zoomButtons }
                        if capability.preset != nil { presetField }
                    }
                }
                stepPicker
                if capability.supportsAbsolute { absolutePanel }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .disabled(controller.isForbidden)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "dpad.fill")
            Text("PTZ")
                .font(.caption.weight(.semibold))
            Spacer()
            outcomeBadge
        }
        .foregroundStyle(.secondary)
    }

    /// Deliberately small and short-lived. A command that worked needs an
    /// acknowledgement, not a dialog.
    @ViewBuilder
    private var outcomeBadge: some View {
        switch controller.outcome {
        case .success(let status):
            Label(status?.capitalized ?? "Sent", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .transition(.opacity)
        case .failure(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .transition(.opacity)
        case nil:
            if controller.isSending {
                ProgressView().controlSize(.mini)
            }
        }
    }

    // MARK: D-pad

    private var dpad: some View {
        VStack(spacing: 4) {
            padButton("chevron.up", "Tilt up") { controller.tilt(1, step: step) }
            HStack(spacing: 4) {
                padButton("chevron.left", "Pan left") { controller.pan(-1, step: step) }
                Circle()
                    .fill(.quaternary)
                    .frame(width: 34, height: 34)
                    .overlay {
                        Text(String(format: "%g°", step))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                padButton("chevron.right", "Pan right") { controller.pan(1, step: step) }
            }
            padButton("chevron.down", "Tilt down") { controller.tilt(-1, step: step) }
        }
    }

    private func padButton(_ symbol: String,
                           _ label: String,
                           action: @escaping () -> Void) -> some View {
        RepeatButton(action: {
            onInteraction()
            action()
        }) {
            Image(systemName: symbol)
                .font(.title3.weight(.bold))
                .frame(width: 44, height: 34)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel(label)
    }

    // MARK: Zoom

    private var zoomButtons: some View {
        HStack(spacing: 4) {
            RepeatButton(action: { onInteraction(); controller.zoom(-1) }) {
                zoomLabel("minus.magnifyingglass")
            }
            .accessibilityLabel("Zoom out")
            RepeatButton(action: { onInteraction(); controller.zoom(1) }) {
                zoomLabel("plus.magnifyingglass")
            }
            .accessibilityLabel("Zoom in")
        }
    }

    private func zoomLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .frame(width: 44, height: 34)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Preset

    /// A field rather than a menu: the schema declares a Text with no
    /// AllowedTokens, so the app genuinely does not know what presets exist and
    /// an empty menu would be a worse lie than an empty field.
    private var presetField: some View {
        HStack(spacing: 4) {
            TextField("Preset", text: $presetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Go") {
                onInteraction()
                controller.goToPreset(presetName)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: Step

    private var stepPicker: some View {
        Picker("Step", selection: Binding(
            get: { settings.config.ptzStepDegrees },
            set: { settings.config.ptzStepDegrees = $0; onInteraction() }
        )) {
            ForEach(PTZController.stepChoices, id: \.self) { choice in
                Text(String(format: "%g°", choice)).tag(choice)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 220)
    }

    // MARK: Absolute

    private var absolutePanel: some View {
        DisclosureGroup("Absolute position", isExpanded: $showsAbsolute) {
            VStack(alignment: .leading, spacing: 6) {
                if let range = capability.position?.pan.range ?? capability.absolutePan?.range {
                    slider("Pan", $absolutePan, range, "%.0f°")
                }
                if let range = capability.position?.tilt.range ?? capability.absoluteTilt?.range {
                    slider("Tilt", $absoluteTilt, range, "%.0f°")
                }
                if let range = capability.position?.zoom.range ?? capability.absoluteZoom?.range {
                    slider("Zoom", $absoluteZoom, range, "%.0f×")
                }
                Button("Go") {
                    onInteraction()
                    controller.goToPosition(pan: absolutePan,
                                            tilt: absoluteTilt,
                                            zoom: absoluteZoom)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
        .font(.caption)
        .onChange(of: showsAbsolute) { _, expanded in
            if expanded { onInteraction(); seedAbsoluteFromRanges() }
        }
    }

    private func slider(_ title: String,
                        _ value: Binding<Double>,
                        _ range: ClosedRange<Double>,
                        _ format: String) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 40, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .frame(width: 50, alignment: .trailing)
        }
    }

    /// Starts the sliders inside their own bounds. Not from the camera's
    /// reported position: the Axis output reports a tilt of 60° while its
    /// command schema accepts [-90, 0], so the two are not the same quantity
    /// and seeding one from the other would put the slider somewhere the
    /// camera will refuse to go.
    private func seedAbsoluteFromRanges() {
        if let range = capability.position?.pan.range ?? capability.absolutePan?.range {
            absolutePan = min(max(absolutePan, range.lowerBound), range.upperBound)
        }
        if let range = capability.position?.tilt.range ?? capability.absoluteTilt?.range {
            absoluteTilt = min(max(absoluteTilt, range.lowerBound), range.upperBound)
        }
        if let range = capability.position?.zoom.range ?? capability.absoluteZoom?.range {
            absoluteZoom = min(max(absoluteZoom, range.lowerBound), range.upperBound)
        }
    }
}

// MARK: - RepeatButton

/// A button that fires once on press and then keeps firing while held.
///
/// Not a `Button`: SwiftUI's has no held state, and a `LongPressGesture`
/// reports the threshold rather than the release. A zero-distance drag is the
/// only gesture that gives both edges of a press, which is what auto-repeat
/// needs — and cancelling on `onEnded` is what stops a camera slewing on after
/// the finger comes off.
struct RepeatButton<Label: View>: View {

    let action: () -> Void
    @ViewBuilder let label: Label

    @State private var isPressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        label
            .contentShape(Rectangle())
            .opacity(isPressed ? 0.55 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in press() }
                    .onEnded { _ in release() }
            )
            .onDisappear { release() }
            // A gesture is invisible to accessibility: without these the pad is
            // a decorative image that VoiceOver cannot press and that nothing
            // driving the app can find. The action fires one move rather than
            // starting a repeat, which is the right meaning for a single
            // activation.
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }

    private func press() {
        guard !isPressed else { return }
        isPressed = true
        action()

        repeatTask = Task {
            try? await Task.sleep(for: PTZController.repeatDelay)
            while !Task.isCancelled {
                action()
                try? await Task.sleep(for: PTZController.repeatInterval)
            }
        }
    }

    private func release() {
        isPressed = false
        repeatTask?.cancel()
        repeatTask = nil
    }
}
