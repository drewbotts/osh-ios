import SwiftUI

// MARK: - SurveyInView
//
// Positioning a remote system from where the phone stands.
//
// Three screens, one per state of SurveyInController: align, review, commit.
// The view has no state of its own beyond text-field scratch space; what is on
// screen is whatever the controller says the survey is doing, so a network
// failure or a cancelled capture cannot leave a screen up that the machine has
// moved on from.

struct SurveyInView: View {

    @StateObject private var controller: SurveyInController
    @Environment(\.dismiss) private var dismiss

    init(system: RemoteSystem, connection: NodeConnection) {
        _controller = StateObject(wrappedValue: SurveyInController(system: system,
                                                                   connection: connection))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch controller.state {
                case .idle, .aligning, .capturing:
                    SurveyAlignmentScreen(controller: controller)
                case .reviewing:
                    SurveyReviewScreen(controller: controller)
                case .committing, .done, .failed:
                    SurveyCommitScreen(controller: controller, onDone: { dismiss() })
                }
            }
            .navigationTitle("Survey-In Position")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if controller.state == .done {
                        Button("Done") { dismiss() }
                    } else {
                        Button("Cancel") { dismiss() }
                            .disabled(controller.state.isCommitting)
                    }
                }
            }
        }
        .interactiveDismissDisabled(controller.state.isCommitting)
        .onAppear { controller.begin() }
        .onDisappear { controller.finish() }
    }
}

// MARK: - Alignment

/// The compass, the live figures, and the capture button.
private struct SurveyAlignmentScreen: View {

    @ObservedObject var controller: SurveyInController
    @ObservedObject var sampler: SurveySampler
    @State private var showsDiagnostics = false

    init(controller: SurveyInController) {
        self.controller = controller
        self.sampler = controller.sampler
    }

    private var reading: SurveySampler.Reading { sampler.reading }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                instructions
                if controller.isPTZ { ptzPanel }
                compass
                figures
                warnings
                diagnostics
                captureControls
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Instructions

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(controller.system.name)
                .font(.headline)
            Text(controller.isPTZ
                 ? "Stand at the camera. Hold the phone level, top edge pointing the way the lens points at pan zero, then capture."
                 : "Stand at the system. Hold the phone level, top edge pointing the way the system faces, then capture.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: PTZ

    private var ptzPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("PTZ camera", systemImage: "dpad.fill")
                .font(.subheadline.weight(.semibold))
            Text("The orientation written must describe the mount's pan-zero (home) axis, not where the lens points now — every pan and tilt the camera reports is relative to it. Send the camera home first, then align with the lens.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let plan = controller.ptzHome {
                HStack(spacing: 10) {
                    Button {
                        controller.sendPTZHome()
                    } label: {
                        Label(plan.isGuess ? "Try PTZ Home" : "Send PTZ Home", systemImage: "house.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.homeOutcome == .sending)
                    homeOutcome
                }
                Text(plan.summary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Label("This camera's schema offers no home or absolute-position command; move it to pan zero by hand.",
                      systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var homeOutcome: some View {
        switch controller.homeOutcome {
        case .sending:
            ProgressView().controlSize(.small)
        case .sent(let status):
            Label(status?.capitalized ?? "Sent", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        case nil:
            EmptyView()
        }
    }

    // MARK: Compass

    private var compass: some View {
        VStack(spacing: 6) {
            SurveyCompassView(headingDegrees: reading.orientation?.heading,
                              accuracyDegrees: validHeadingAccuracy)
                .frame(width: 260, height: 260)
            if let heading = reading.orientation?.heading {
                Text(String(format: "%.1f°", heading))
                    .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                Text(reading.hasTrueNorth ? "true north" : "magnetic — waiting for a fix to apply declination")
                    .font(.caption)
                    .foregroundStyle(reading.hasTrueNorth ? Color.secondary : Color.orange)
            } else {
                Text("waiting for the motion sensors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var validHeadingAccuracy: Double? {
        guard let accuracy = reading.headingAccuracy, accuracy >= 0 else { return nil }
        return accuracy
    }

    // MARK: Figures

    private var figures: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            if let location = reading.location {
                figureRow("Latitude", String(format: "%.6f°", location.latitude))
                figureRow("Longitude", String(format: "%.6f°", location.longitude))
                figureRow("HAE", String(format: "%.1f m", location.ellipsoidalAltitude), hint: "written")
                figureRow("MSL", String(format: "%.1f m", location.altitudeMSL), hint: "reference")
                figureRow("Horizontal accuracy",
                          String(format: "± %.1f m", location.horizontalAccuracy),
                          warn: location.horizontalAccuracy > SurveyInController.poorHorizontalAccuracy)
            } else {
                figureRow("Position", "waiting for a fix")
            }
            figureRow("Heading accuracy",
                      validHeadingAccuracy.map { String(format: "± %.0f°", $0) } ?? "unknown",
                      warn: (validHeadingAccuracy ?? 0) > SurveyInController.poorHeadingAccuracy)
            figureRow("Magnetometer", reading.calibration.label, warn: reading.calibration.isPoor)
        }
        .font(.callout.monospacedDigit())
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func figureRow(_ label: String, _ value: String,
                           hint: String? = nil, warn: Bool = false) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            HStack(spacing: 6) {
                Text(value)
                    .foregroundStyle(warn ? Color.orange : Color.primary)
                if let hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Warnings

    @ViewBuilder
    private var warnings: some View {
        if let failure = sampler.failure {
            warning(failure, symbol: "xmark.octagon.fill", color: .red)
        }
        if (validHeadingAccuracy ?? 0) > SurveyInController.poorHeadingAccuracy || reading.calibration.isPoor {
            warning("Compass accuracy is poor — metal mounts and tripods do this. Step back from the housing and sweep the phone in a figure-eight; if it stays poor, capture anyway and correct the heading by eye on the next screen.",
                    symbol: "exclamationmark.triangle.fill", color: .orange)
        }
        if let accuracy = reading.location?.horizontalAccuracy,
           accuracy > SurveyInController.poorHorizontalAccuracy {
            warning("Position accuracy is poor. Wait for the receiver to settle before capturing.",
                    symbol: "location.slash", color: .orange)
        }
    }

    private func warning(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Diagnostics

    /// Three headings side by side. Which of them a lens alignment should
    /// follow is a question only a phone in the field can settle, and this is
    /// where it is settled.
    private var diagnostics: some View {
        DisclosureGroup("Heading sources", isExpanded: $showsDiagnostics) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                figureRow("CMDeviceMotion.heading", degrees(reading.orientation?.heading), hint: "used")
                figureRow("−yaw (publisher's)", degrees(reading.yawHeading))
                figureRow("CLHeading.trueHeading", degrees(reading.compassTrueHeading))
                if let orientation = reading.orientation {
                    figureRow("Phone pitch / roll",
                              String(format: "%.1f° / %.1f°", orientation.pitch, orientation.roll))
                }
            }
            .font(.caption.monospacedDigit())
            .padding(.top, 4)
        }
        .font(.caption)
        .padding(.horizontal, 4)
    }

    private func degrees(_ value: Double?) -> String {
        value.map { String(format: "%.1f°", $0) } ?? "—"
    }

    // MARK: Capture

    @ViewBuilder
    private var captureControls: some View {
        if case .capturing(let progress) = controller.state {
            VStack(spacing: 8) {
                ProgressView(value: progress)
                Text("Hold still — averaging \(Int(SurveyInController.captureDuration)) seconds of fixes and headings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel capture", role: .cancel) { controller.cancelCapture() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        } else {
            Button {
                controller.startCapture()
            } label: {
                Label("Capture (\(Int(SurveyInController.captureDuration)) s)", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!controller.canCapture)
        }
    }
}

// MARK: - Review

/// The averaged figures, with the adjustments the user is allowed to make.
private struct SurveyReviewScreen: View {

    @ObservedObject var controller: SurveyInController
    @State private var heightText = ""
    @FocusState private var heightFocused: Bool

    private var review: SurveyInController.Review? { controller.review }

    var body: some View {
        if let review {
            Form {
                positionSection(review)
                heightSection(review)
                headingSection(review)
                attitudeSection(review)
                previewSection(review)
                actions
            }
            .onAppear { heightText = String(format: "%.1f", review.baseHeight) }
        } else {
            ContentUnavailableView("Nothing captured", systemImage: "scope")
        }
    }

    // MARK: Position

    private func positionSection(_ review: SurveyInController.Review) -> some View {
        Section {
            LabeledContent("Latitude", value: String(format: "%.6f°", review.position.latitude))
            LabeledContent("Longitude", value: String(format: "%.6f°", review.position.longitude))
            LabeledContent("Horizontal accuracy",
                           value: String(format: "± %.1f m", review.position.horizontalAccuracy))
                .foregroundStyle(review.position.horizontalAccuracy > SurveyInController.poorHorizontalAccuracy
                                 ? Color.orange : Color.primary)
            if let vertical = review.position.verticalAccuracy {
                LabeledContent("Vertical accuracy", value: String(format: "± %.1f m", vertical))
            }
            LabeledContent("Fixes averaged", value: "\(review.position.sampleCount)")
        } header: {
            Text("Position")
        }
        .monospacedDigit()
    }

    // MARK: Height

    private func heightSection(_ review: SurveyInController.Review) -> some View {
        Section {
            Picker("Height datum", selection: Binding(
                get: { controller.review?.heightDatum ?? .hae },
                set: { controller.review?.heightDatum = $0 })) {
                ForEach(SurveyInController.HeightDatum.allCases, id: \.self) { datum in
                    Text(datum.label).tag(datum)
                }
            }
            .pickerStyle(.segmented)

            LabeledContent {
                HStack(spacing: 4) {
                    TextField("metres", text: $heightText)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .focused($heightFocused)
                        .frame(width: 100)
                        .onChange(of: heightText) { _, text in
                            guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else { return }
                            if controller.review?.heightDatum == .msl {
                                controller.review?.altitudeMSL = value
                            } else {
                                controller.review?.heightAboveEllipsoid = value
                            }
                        }
                    Text("m")
                        .foregroundStyle(.secondary)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(review.heightDatum == .hae ? "HAE (written)" : "MSL (written)")
                    Text(String(format: "measured %.1f m",
                                review.heightDatum == .hae
                                    ? review.position.heightAboveEllipsoid
                                    : review.position.altitudeMSL))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent {
                Text(String(format: "%.1f m",
                            review.heightDatum == .hae ? review.position.altitudeMSL
                                                       : review.position.heightAboveEllipsoid))
                    .foregroundStyle(.secondary)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(review.heightDatum == .hae ? "MSL (reference)" : "HAE (reference)")
                    Text(review.heightDatum == .hae ? "what a GPS app shows; not written"
                                                    : "ellipsoid height; not written")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Stepper(String(format: "Mount offset %+.1f m", review.mountOffset),
                    value: Binding(get: { controller.review?.mountOffset ?? 0 },
                                   set: { controller.review?.mountOffset = ($0 * 10).rounded() / 10 }),
                    in: SurveyInController.mountOffsetRange,
                    step: SurveyInController.mountOffsetStep)

            LabeledContent("Written height") {
                Text(String(format: "%.1f m %@", review.writtenHeight,
                            review.heightDatum == .hae ? "HAE" : "MSL"))
                    .font(.body.weight(.semibold))
            }

            if review.writesMSLIntoEllipsoidalSlot {
                Label("The field this goes into is defined as height above the WGS 84 ellipsoid. An MSL value will be stored under that definition — deliberate, but consumers that trust the datum will be off by the local geoid height.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Height")
        } footer: {
            Text("HAE is what EPSG 4979 and the driver's location output define. It differs from sea-level altitude by the local geoid height, often tens of metres. The mount offset is the height of the mount above (or below) where the phone was held.")
        }
        .monospacedDigit()
        .onChange(of: review.heightDatum) { _, datum in
            heightText = String(format: "%.1f",
                                datum == .hae ? review.heightAboveEllipsoid : review.altitudeMSL)
        }
    }

    // MARK: Heading

    private func headingSection(_ review: SurveyInController.Review) -> some View {
        Section {
            LabeledContent("Measured",
                           value: String(format: "%.1f° ± %.1f°", review.heading.heading, review.heading.spread))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Adjustment")
                    Spacer()
                    Stepper(String(format: "%+.1f°", review.headingAdjustment),
                            value: adjustmentBinding,
                            in: SurveyInController.headingAdjustmentRange,
                            step: SurveyInController.headingAdjustmentStep)
                        .fixedSize()
                }
                Slider(value: adjustmentBinding,
                       in: SurveyInController.headingAdjustmentRange,
                       step: SurveyInController.headingAdjustmentStep) {
                    Text("Heading adjustment")
                } minimumValueLabel: {
                    Text("−30°").font(.caption2)
                } maximumValueLabel: {
                    Text("+30°").font(.caption2)
                }
                if review.headingAdjustment != 0 {
                    Button("Reset adjustment") { controller.review?.headingAdjustment = 0 }
                        .font(.caption)
                }
            }
            LabeledContent("Written heading") {
                Text(String(format: "%.1f° true", review.finalHeading))
                    .font(.body.weight(.semibold))
            }
            LabeledContent("Headings averaged", value: "\(review.heading.sampleCount)")
        } header: {
            Text("Heading")
        } footer: {
            Text("Degrees clockwise from true north, written as the GeoPose yaw in a north-east-down frame. Correct it here if the compass was pulled by the mount.")
        }
        .monospacedDigit()
    }

    private var adjustmentBinding: Binding<Double> {
        Binding(get: { controller.review?.headingAdjustment ?? 0 },
                set: { controller.review?.headingAdjustment = $0 })
    }

    // MARK: Attitude

    private func attitudeSection(_ review: SurveyInController.Review) -> some View {
        Section {
            Stepper(String(format: "Pitch %.1f°", review.pitch),
                    value: Binding(get: { controller.review?.pitch ?? 0 },
                                   set: { controller.review?.pitch = $0 }),
                    in: -90...90, step: SurveyInController.attitudeStep)
            Stepper(String(format: "Roll %.1f°", review.roll),
                    value: Binding(get: { controller.review?.roll ?? 0 },
                                   set: { controller.review?.roll = $0 }),
                    in: -180...180, step: SurveyInController.attitudeStep)
            if let attitude = review.attitude {
                Button(String(format: "Use the phone's measured %.1f° / %.1f°", attitude.pitch, attitude.roll)) {
                    controller.review?.pitch = attitude.pitch
                    controller.review?.roll = attitude.roll
                }
                .font(.caption)
            }
        } header: {
            Text("Mount pitch and roll (written)")
        } footer: {
            Text("Zero for a level base. Use the phone's own figures only if it was lying flat on the housing when captured.")
        }
        .monospacedDigit()
    }

    // MARK: Preview

    /// Where the write goes and exactly what it says.
    private func previewSection(_ review: SurveyInController.Review) -> some View {
        Section {
            ForEach(Array(controller.previewBodies().enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(entry.body
                            .replacingOccurrences(of: ",\"", with: ",\n\"")
                            .replacingOccurrences(of: "{\"", with: "{\n\""))
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Will write to \(controller.strategy.summary)")
        } footer: {
            if case .staticOutputs = controller.strategy {
                Text("This system publishes its configured emplacement as outputs; a new observation on them is a new emplacement. The system description is left alone.")
            } else {
                Text("This system has no position outputs yet. The two the driver would have published — sensorLocation and sensorOrientation, in the same shape — are created on it, then written. The system description is left alone.")
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        Section {
            Button {
                heightFocused = false
                controller.commit()
            } label: {
                Label("Write to \(controller.system.name)", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            .listRowBackground(Color.clear)

            Button {
                controller.retry()
            } label: {
                Label("Retry capture", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 6, trailing: 8))
            .listRowBackground(Color.clear)
        } footer: {
            Text("Nothing is sent to the node until you tap Write. The description is read, its position replaced, and the result written back and re-read to confirm.")
        }
    }
}

// MARK: - Commit

/// Progress, then the outcome — with the whole exchange when it went wrong.
private struct SurveyCommitScreen: View {

    @ObservedObject var controller: SurveyInController
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                switch controller.state {
                case .committing:
                    ProgressView()
                        .controlSize(.large)
                        .padding(.top, 60)
                    Text("Writing the position to \(controller.system.name)…")
                        .foregroundStyle(.secondary)

                case .done:
                    doneBody

                case .failed(let failure):
                    failedBody(failure)

                default:
                    EmptyView()
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private var doneBody: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .padding(.top, 30)
            Text("Position written")
                .font(.title2.weight(.semibold))
            if let pose = controller.written {
                Text(SurveyInController.describe(pose))
                    .font(.callout.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Text(controller.strategy == .createOutputs
                 ? "The system now has sensorLocation and sensorOrientation outputs carrying this position; the Systems list and the map are reloading it."
                 : "The node's newest records on the static outputs carry this position; the Systems list and the map are reloading it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { onDone() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
        }
    }

    private func failedBody(_ failure: SurveyInController.SurveyFailure) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(failure.title, systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)
            Text(failure.detail)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if failure.resumesAtReview {
                    Button("Back to review") { controller.backToReview() }
                        .buttonStyle(.borderedProminent)
                    Button("Try again") { controller.backToReview(); controller.commit() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Back to alignment") { controller.retry() }
                        .buttonStyle(.borderedProminent)
                }
            }

            if let request = failure.request {
                exchange("Request", request)
            }
            if let response = failure.response {
                exchange("Response", response)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exchange(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Text(text)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxHeight: 260)
        }
    }
}
