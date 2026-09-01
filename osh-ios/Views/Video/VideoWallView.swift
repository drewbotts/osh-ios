import SwiftUI

// MARK: - VideoWallView
//
// Every camera at once: this device's, and every video datastream on the node.
//
// The old Camera tab showed one preview — this phone's — and the node's cameras
// were buried one at a time inside per-system dashboards. That is backwards for
// the thing an OSH node is for. A wall is what lets someone see that the yard
// camera and the phone in their hand are both looking at the same incident.
//
// This device keeps the first tile and the old Camera tab's controls, now one
// tap away rather than a whole tab; the node's cameras follow. Playback is
// capped and metered — see VideoWallModel.

struct VideoWallView: View {

    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var session: SensorSession
    @EnvironmentObject private var connections: NodeConnectionStore
    @EnvironmentObject private var activity: ActivityTracker
    @StateObject private var network = NetworkPathObserver.shared

    @StateObject private var model = VideoWallModel()

    @State private var fullScreen: VideoWallModel.Tile?
    /// Autoplay runs once per appearance, not on every layout pass.
    @State private var hasAutoplayed = false

    // MARK: Body

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    LazyVGrid(columns: columns(for: geometry.size), spacing: 12) {
                        if settings.config.enableVideoH264 {
                            deviceTile
                        }
                        ForEach(model.tiles) { tile in
                            NodeVideoTile(tile: tile,
                                          model: model,
                                          activity: model.activityState(tile))
                                .onTapGesture { fullScreen = tile }
                        }
                    }
                    .padding(12)

                    status
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .refreshable { await model.load(connection: connections.active, refresh: true) }
            .task(id: connections.active?.server.id) {
                network.start()
                await model.load(connection: connections.active)
                autoplayIfWanted()
            }
            .onDisappear { model.stopAll(); hasAutoplayed = false }
            .fullScreenCover(item: $fullScreen) { tile in
                NodeVideoPlayerView(tile: tile, model: model)
            }
        }
    }

    /// Two up in portrait, three across in landscape. Any more and an MJPEG
    /// tile is smaller than the frames arriving into it.
    private func columns(for size: CGSize) -> [GridItem] {
        let count = size.width > size.height ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    // MARK: This device

    private var deviceTile: some View {
        NavigationLink {
            DeviceCameraView()
        } label: {
            VideoTileFrame(title: "This Device",
                           subtitle: settings.config.videoConfig.codec == VideoConfig.codecH264
                               ? "H.264" : settings.config.videoConfig.codec,
                           activity: activity.localDeviceActivity.state) {
                ZStack {
                    if let captureSession = session.videoCaptureSession, isStreaming {
                        CameraPreviewView(captureSession: captureSession)
                    } else {
                        Color.black.opacity(0.9)
                        Text("start a session to preview")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(6)
                    }
                }
            } footer: {
                Text(deviceStatsText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(.plain)
    }

    private var deviceStatsText: String {
        guard let stats = session.videoStats, stats.hasDimensions else {
            return isStreaming ? "waiting for frames" : "tap for camera settings"
        }
        return String(format: "%d×%d · %.1f fps · %.0f kbps",
                      stats.width, stats.height, stats.encodedFPS, stats.bitrateKbps)
    }

    private var isStreaming: Bool {
        if case .streaming = session.state { return true }
        return false
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Autoplay", selection: $settings.config.videoAutoplay) {
                    ForEach(VideoAutoplay.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                Button("Pause all", systemImage: "pause.fill") { model.stopAll() }
                    .disabled(model.playing.isEmpty)
                Button("Play up to \(VideoWallModel.maxPlaying)", systemImage: "play.fill") {
                    model.autoplay()
                }
            } label: {
                Label("Playback", systemImage: "play.rectangle")
            }
        }
    }

    private func autoplayIfWanted() {
        guard !hasAutoplayed else { return }
        hasAutoplayed = true
        guard network.shouldAutoplay(settings.config.videoAutoplay) else {
            Log.client.info("Video wall autoplay held back (setting \(settings.config.videoAutoplay.rawValue, privacy: .public), unmetered \(network.isUnmetered))")
            return
        }
        model.autoplay()
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.isLoading && model.tiles.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Loading cameras…") }
            } else if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if model.tiles.isEmpty && !settings.config.enableVideoH264 {
                Text("No video on this node, and this device's camera is switched off in Settings.")
            } else {
                Text("\(model.playing.count) of \(VideoWallModel.maxPlaying) streams playing")
                if !network.isUnmetered {
                    Label("on cellular", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 20)
    }
}

// MARK: - VideoTileFrame

/// The chrome every tile shares: a header naming the source, a status dot, a
/// codec badge, a 16:9 picture area and a line of numbers.
///
/// Shared so the phone's own preview and a node camera are visibly the same
/// kind of thing — which is the whole argument for putting them on one wall.
struct VideoTileFrame<Content: View, Footer: View>: View {

    let title: String
    let subtitle: String?
    let activity: ActivityState
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ActivityDot(state: activity)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                }
            }

            content
                .aspectRatio(16 / 9, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            footer
        }
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - NodeVideoTile

/// One node camera on the wall.
struct NodeVideoTile: View {

    let tile: VideoWallModel.Tile
    @ObservedObject var model: VideoWallModel
    let activity: ActivityState

    var body: some View {
        VideoTileFrame(title: tile.systemName,
                       subtitle: tile.compression,
                       activity: activity) {
            ZStack {
                Color.black.opacity(0.9)
                if let frame = model.frame(tile), tile.isDecodable {
                    Image(decorative: frame.image, scale: 1, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    placeholder
                }
            }
            // Playback control on the tile itself, so the wall can be curated
            // without opening every camera full screen — which is the whole
            // point of a four-stream cap the user can spend deliberately.
            .overlay(alignment: .bottomLeading) {
                Button {
                    model.isPlaying(tile) ? model.pause(tile) : model.play(tile)
                } label: {
                    Image(systemName: model.isPlaying(tile) ? "pause.circle.fill"
                                                            : "play.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel(model.isPlaying(tile) ? "Pause \(tile.systemName)"
                                                          : "Play \(tile.systemName)")
            }
        } footer: {
            HStack(spacing: 6) {
                if let frame = model.frame(tile) {
                    Text("\(frame.width)×\(frame.height)")
                }
                Spacer()
                if let stats = model.stats(tile), stats.frames > 0 {
                    Text(String(format: "%.1f fps", stats.fps))
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tile.systemName), \(activity.label), \(model.isPlaying(tile) ? "playing" : "paused")")
    }

    @ViewBuilder
    private var placeholder: some View {
        if !model.isPlaying(tile) {
            Label("tap to play", systemImage: "play.circle")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
        } else if !tile.isDecodable {
            // Not an error: an H.264 camera is working perfectly and the app
            // has not learned to draw it yet. The arrival figures below say so.
            VStack(spacing: 3) {
                Image(systemName: "film.stack")
                Text(tile.compression ?? "codec")
                Text("preview not yet supported")
            }
            .font(.caption2)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.75))
            .padding(4)
        } else {
            ProgressView()
                .tint(.white)
        }
    }
}

#Preview {
    VideoWallView()
        .previewEnvironment()
}
