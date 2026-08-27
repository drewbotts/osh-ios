import SwiftUI

// MARK: - MJPEGView
//
// The picture, plus enough numbers to tell a stalled stream from a slow one.
//
// The frame arrives already decoded — SystemLiveSession does that off the main
// actor — so this is an Image and an overlay. Play and pause open and close the
// subscription rather than freezing the display: a paused camera whose socket
// stayed open would go on costing bandwidth for a still picture.

struct MJPEGView: View {

    /// Named `latestFrame` rather than `frame` so it cannot be mistaken for
    /// SwiftUI's `frame(...)` modifier at a call site inside `body`.
    let latestFrame: DecodedFrame?
    let stats: SystemLiveSession.BlockStats?
    let compression: String?
    let isPlaying: Bool
    let onPlay: () -> Void
    let onPause: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.9))

                if let latestFrame {
                    Image(decorative: latestFrame.image, scale: 1, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(isPlaying ? "waiting for frames" : "paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                overlay
            }
            .frame(height: 170)

            footer
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Overlay

    private var overlay: some View {
        VStack {
            HStack {
                Spacer()
                if let latestFrame {
                    Text(latestFrame.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.45), in: Capsule())
                }
            }
            Spacer()
            HStack {
                Button {
                    isPlaying ? onPause() : onPlay()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause video" : "Play video")
                Spacer()
            }
        }
        .padding(8)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let compression {
                Text(compression)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.18), in: Capsule())
            }
            if let latestFrame {
                Text("\(latestFrame.width)×\(latestFrame.height)")
                    .font(.caption2.monospacedDigit())
            }
            Spacer()
            if let stats, stats.frames > 0 {
                Text(String(format: "%.1f fps · %@",
                            stats.fps,
                            ByteCountFormatter.string(fromByteCount: Int64(stats.lastByteCount),
                                                      countStyle: .binary)))
                    .font(.caption2.monospacedDigit())
            }
        }
        .foregroundStyle(.secondary)
    }

    private var accessibilityLabel: String {
        guard let latestFrame else { return isPlaying ? "Video, waiting for frames" : "Video, paused" }
        return "Video, \(latestFrame.width) by \(latestFrame.height), "
            + String(format: "%.1f frames per second", stats?.fps ?? 0)
    }
}

// MARK: - UnsupportedCodecView

/// What a stream this pass cannot decode looks like.
///
/// Deliberately not an error: an H.264 camera on the node is working perfectly
/// and the app simply has not learned to draw it yet. Showing the arrival rate
/// and frame sizes proves that much, and is what makes the difference between
/// "not implemented" and "broken" visible without opening the Logs tab.
struct UnsupportedCodecView: View {

    let compression: String?
    let stats: SystemLiveSession.BlockStats?
    let isPlaying: Bool
    let onPlay: () -> Void
    let onPause: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "film.stack")
                    .foregroundStyle(.secondary)
                Text("\(compression ?? "This codec") preview not yet supported — Pass 3d")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let stats, stats.frames > 0 {
                Text(String(format: "%d frames · %.1f fps · %@ per frame",
                            stats.frames, stats.fps,
                            ByteCountFormatter.string(fromByteCount: Int64(stats.lastByteCount),
                                                      countStyle: .binary)))
                    .font(.caption2.monospacedDigit())
            } else {
                Text(isPlaying ? "waiting for frames" : "not subscribed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button(isPlaying ? "Stop" : "Check stream",
                   systemImage: isPlaying ? "stop.fill" : "play.fill") {
                isPlaying ? onPause() : onPlay()
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
