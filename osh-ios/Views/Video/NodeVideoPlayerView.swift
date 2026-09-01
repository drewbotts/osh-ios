import SwiftUI

// MARK: - NodeVideoPlayerView
//
// One node camera, full screen, with its controls on top of it.
//
// This is the payoff of the whole pass. Everything before it — role inference,
// the schema decoder, control-stream discovery, PTZ recognition — exists so
// that tapping a tile on a wall of cameras the app has never seen before gives
// you a picture and, if that camera will accept one, a D-pad that moves it.
//
// The overlay hides itself after four seconds because the picture is the point;
// it comes back on a tap and stays while a button is held, which is what makes
// holding down "pan left" watchable.

struct NodeVideoPlayerView: View {

    let tile: VideoWallModel.Tile
    @ObservedObject var model: VideoWallModel

    @EnvironmentObject private var connections: NodeConnectionStore
    @Environment(\.dismiss) private var dismiss

    @State private var controller: PTZController?
    @State private var showsControls = true
    @State private var lastInteraction = Date()

    /// How long the overlay stays up after the last touch.
    private static let autoHide: TimeInterval = 4

    // MARK: Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            picture
            if showsControls { chrome } else { restingChrome }
        }
        .statusBarHidden()
        .contentShape(Rectangle())
        .onTapGesture { reveal() }
        .onAppear(perform: open)
        .task { await autoHideLoop() }
    }

    // MARK: Picture

    @ViewBuilder
    private var picture: some View {
        if let frame = model.frame(tile), tile.isDecodable {
            Image(decorative: frame.image, scale: 1, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .ignoresSafeArea()
        } else if !tile.isDecodable {
            UnsupportedCodecView(compression: tile.compression,
                                 stats: model.stats(tile),
                                 isPlaying: model.isPlaying(tile),
                                 onPlay: { model.play(tile) },
                                 onPause: { model.pause(tile) })
                .padding(28)
                .foregroundStyle(.white)
        } else {
            VStack(spacing: 8) {
                ProgressView().tint(.white)
                Text(model.isPlaying(tile) ? "waiting for frames" : "paused")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    // MARK: Chrome

    /// What is left when the overlay hides itself.
    ///
    /// Not nothing. A full-screen cover has no swipe-to-dismiss, so hiding every
    /// control would leave the only way out being a tap the user has no reason
    /// to think would work. Two small buttons in the corners cost almost none of
    /// the picture and mean the screen is never a trap.
    private var restingChrome: some View {
        VStack {
            HStack {
                cornerButton("xmark", "Close") { dismiss() }
                Spacer()
                cornerButton("slider.horizontal.3", "Show controls") { reveal() }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private func cornerButton(_ symbol: String,
                              _ label: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if let controller {
                PTZControlView(controller: controller, onInteraction: reveal)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .frame(maxWidth: 480)
            } else if let system = model.system(tile), system.isCommandable {
                // A control stream the app understood but could not turn into a
                // PTZ camera. Saying so beats an empty screen that looks like a
                // missing feature.
                Label("command support for this structure not yet implemented",
                      systemImage: "slider.horizontal.3")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 20)
            }
        }
        .transition(.opacity)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.4))
            }
            .accessibilityLabel("Close")

            VStack(alignment: .leading, spacing: 1) {
                Text(tile.systemName)
                    .font(.subheadline.weight(.semibold))
                Text(statsText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            ActivityDot(state: model.activityState(tile), size: 10, ringColor: .black.opacity(0.3))
            Button {
                reveal()
                model.isPlaying(tile) ? model.pause(tile) : model.play(tile)
            } label: {
                Image(systemName: model.isPlaying(tile) ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.4))
            }
            .accessibilityLabel(model.isPlaying(tile) ? "Pause" : "Play")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.35))
    }

    private var statsText: String {
        var parts: [String] = []
        if let compression = tile.compression { parts.append(compression) }
        if let frame = model.frame(tile) { parts.append("\(frame.width)×\(frame.height)") }
        if let stats = model.stats(tile), stats.frames > 0 {
            parts.append(String(format: "%.1f fps", stats.fps))
        }
        return parts.isEmpty ? tile.datastreamName : parts.joined(separator: " · ")
    }

    // MARK: Behaviour

    /// Starts the stream and builds a controller if this camera takes commands.
    private func open() {
        if !model.isPlaying(tile) { model.play(tile) }
        guard controller == nil,
              let connection = connections.active,
              let capability = model.system(tile)?.ptzCapability else { return }
        controller = PTZController(capability: capability, connection: connection)
    }

    private func reveal() {
        lastInteraction = Date()
        guard !showsControls else { return }
        withAnimation(.easeOut(duration: 0.2)) { showsControls = true }
    }

    /// One slow loop rather than a timer per interaction: the overlay only has
    /// to notice the pause within a second of it happening.
    private func autoHideLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard Date().timeIntervalSince(lastInteraction) >= Self.autoHide,
                  showsControls else { continue }
            withAnimation(.easeOut(duration: 0.3)) { showsControls = false }
        }
    }
}
