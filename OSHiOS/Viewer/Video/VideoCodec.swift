import Foundation

// MARK: - VideoCodec
//
// What a Block member's `compression` code means to this app.
//
// The node spells codecs loosely — "JPEG" and "MJPEG" for one, "H264" and
// "avc1" for another — and a schema may carry none at all, so this is a
// recognition rather than a lookup. It is the single place that decides which
// decoder a video datastream gets, so a tile, a card and the live session all
// agree on whether a stream can be drawn.

enum VideoCodec: Equatable, Sendable {
    /// Every observation is one whole JPEG.
    case jpeg
    /// Annex-B H.264 access units, one per observation.
    case h264
    /// A codec the app counts and sizes but cannot draw.
    case unsupported(String?)

    init(compression: String?) {
        guard let compression else {
            self = .unsupported(nil)
            return
        }
        let normalized = compression.lowercased()
        if normalized.contains("jpeg") || normalized.contains("jpg") {
            self = .jpeg
        } else if normalized.contains("264") || normalized.contains("avc") {
            self = .h264
        } else {
            self = .unsupported(compression)
        }
    }

    /// Whether frames of this codec become pictures.
    var isDecodable: Bool {
        switch self {
        case .jpeg, .h264:  return true
        case .unsupported:  return false
        }
    }
}
