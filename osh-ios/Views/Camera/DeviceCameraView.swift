import SwiftUI
import AVFoundation

// MARK: - DeviceCameraView
//
// Live preview while streaming, and the encoder settings otherwise. The
// settings are locked during a session because the datastream is registered
// with the resolution and codec the node will receive — changing them mid-run
// would make the registered schema a lie.
//
// This was the Camera tab until the video wall absorbed it. Nothing inside
// changed: the wall shows this device's preview as its first tile and pushes
// here for the controls, which is one tap further away and one whole tab
// cheaper.

struct DeviceCameraView: View {

    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var session: SensorSession

    var body: some View {
        Group {
            if settings.config.enableVideoH264 {
                enabledContent
            } else {
                disabledContent
            }
        }
        .navigationTitle("This Device")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Enabled

    private var enabledContent: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                preview(height: geometry.size.height * 0.6)
                controls
            }
        }
    }

    @ViewBuilder
    private func preview(height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            if let captureSession = session.videoCaptureSession, isStreaming {
                CameraPreviewView(captureSession: captureSession)
                overlayStrip
            } else {
                Rectangle()
                    .fill(Color(.secondarySystemBackground))
                    .overlay {
                        ContentUnavailableView {
                            Label("Preview offline", systemImage: "video.slash")
                        } description: {
                            Text("Start a session on the Live tab to see the camera.")
                        }
                    }
            }
        }
        .frame(height: max(height, 160))
        .clipped()
    }

    private var overlayStrip: some View {
        Text(overlayText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.55))
    }

    private var overlayText: String {
        guard let stats = session.videoStats, stats.hasDimensions else {
            return "waiting for frames"
        }
        return String(format: "%d×%d • %.1f fps • %.0f kbps • dropped %d",
                      stats.width, stats.height,
                      stats.encodedFPS, stats.bitrateKbps, stats.droppedFrames)
    }

    // MARK: Controls

    // Each section is disabled on its own rather than the whole Form: a
    // disabled Form swallows scroll gestures too, so the settings below the
    // fold become unreachable while a session is streaming.
    private var controls: some View {
        Form {
            Section("Encoder") {
                Picker("Codec", selection: $settings.config.videoConfig.codec) {
                    ForEach(VideoConfig.availableCodecs, id: \.self) { codec in
                        Text(codec == VideoConfig.codecH264 ? "H.264" : codec).tag(codec)
                    }
                }

                Picker("Resolution", selection: $settings.config.videoConfig.selectedPreset) {
                    ForEach(Array(settings.config.videoConfig.presets.enumerated()), id: \.offset) { index, preset in
                        Text(preset.displayName).tag(index)
                    }
                }

                Picker("Frame Rate", selection: $settings.config.videoConfig.frameRate) {
                    ForEach(VideoConfig.availableFrameRates, id: \.self) { fps in
                        Text("\(fps) fps").tag(fps)
                    }
                }
            }
            .disabled(session.isActive)

            Section {
                bitrateSlider
                    .disabled(session.isActive)
            } header: {
                Text("Bitrate")
            } footer: {
                if session.isActive {
                    Text("Stop streaming to change video settings.")
                }
            }
        }
        .scrollContentBackground(.automatic)
    }

    @ViewBuilder
    private var bitrateSlider: some View {
        let index = settings.config.videoConfig.selectedPreset
        if settings.config.videoConfig.presets.indices.contains(index) {
            let preset = settings.config.videoConfig.presets[index]
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Target", value: "\(preset.selectedBitrate) kbps")
                Slider(value: bitrateBinding(for: index),
                       in: Double(preset.minBitrate)...Double(preset.maxBitrate),
                       step: 250) {
                    Text("Bitrate")
                } minimumValueLabel: {
                    Text("\(preset.minBitrate)").font(.caption2)
                } maximumValueLabel: {
                    Text("\(preset.maxBitrate)").font(.caption2)
                }
            }
        }
    }

    /// Writes back into the selected preset so each resolution keeps its own
    /// bitrate — switching to 1080p and back should not silently reset 720p.
    private func bitrateBinding(for index: Int) -> Binding<Double> {
        Binding(
            get: { Double(settings.config.videoConfig.presets[index].selectedBitrate) },
            set: { settings.config.videoConfig.presets[index].selectedBitrate = Int($0) }
        )
    }

    // MARK: Disabled

    private var disabledContent: some View {
        Form {
            Section {
                ContentUnavailableView {
                    Label("Video is off", systemImage: "video.slash")
                } description: {
                    Text("Enable H.264 video to stream camera frames to the OSH node. Frames are posted one per observation, so a low frame rate keeps the load reasonable.")
                }
                .listRowBackground(Color.clear)

                Toggle("Video H264", isOn: $settings.config.enableVideoH264)
                    .disabled(session.isActive)
            }
        }
    }

    private var isStreaming: Bool {
        if case .streaming = session.state { return true }
        return false
    }
}

#Preview {
    NavigationStack {
        DeviceCameraView()
    }
    .previewEnvironment()
}
