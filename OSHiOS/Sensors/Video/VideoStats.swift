import Foundation

// MARK: - VideoStats
//
// What the encoder is actually producing, as opposed to what VideoConfig asked
// for. The two diverge in normal use: the capture device may not honour the
// requested frame duration, VBR means the bitrate floats, and frames are
// dropped whenever a POST is still in flight. The Camera tab shows this rather
// than the configured values so the numbers on screen are the real ones.

struct VideoStats: Sendable, Equatable {
    /// Frames encoded per second, measured over the last reporting window.
    var encodedFPS: Double = 0
    /// Encoded throughput in kbit/s over the same window.
    var bitrateKbps: Double = 0
    /// Cumulative frames dropped because the previous POST had not finished.
    var droppedFrames: Int = 0
    /// Encoded frame dimensions, from the first frame seen.
    var width: Int = 0
    var height: Int = 0

    var hasDimensions: Bool { width > 0 && height > 0 }
}
