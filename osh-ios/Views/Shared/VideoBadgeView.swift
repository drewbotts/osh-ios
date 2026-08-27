import SwiftUI

// MARK: - VideoBadgeView
//
// Encoder health for a *local* camera output: resolution, frame rate, dropped
// frames. There is nothing to show of the picture itself — the frames are
// already compressed and on their way to the node — so the numbers are the
// whole card.
//
// Its remote counterpart is MJPEGView, which has actual pixels to draw.

struct VideoBadgeView: View {

    let stats: VideoStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("video")
                .font(.callout)
            if let stats, stats.hasDimensions {
                Text("\(stats.width)×\(stats.height)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f fps · dropped %d",
                            stats.encodedFPS, stats.droppedFrames))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("waiting for frames")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
