import Foundation
import CoreGraphics
import ImageIO

// MARK: - DecodedFrame

/// One decoded video frame, ready to draw.
///
/// @unchecked Sendable: CGImage is an immutable Core Graphics object — it is
/// created here and never mutated, and the SDK does not yet mark the type — so
/// handing one across an isolation boundary is safe in the way the compiler
/// cannot check.
struct DecodedFrame: @unchecked Sendable {
    let image: CGImage
    let timestamp: Date
    /// Size of the compressed frame this came from, for the bitrate readout.
    let byteCount: Int

    var width: Int { image.width }
    var height: Int { image.height }
}

// MARK: - MJPEGDecoder
//
// Motion JPEG is a video codec only by convention: every observation on the
// stream is a whole, independent JPEG, so there is no decoder state to keep and
// no frame that depends on another. ImageIO does the work.
//
// An actor rather than a namespace of static functions, because decoding a
// 1280×720 JPEG takes long enough to drop a frame of UI if it happens on the
// main actor, and a SystemLiveSession is @MainActor. Isolation is what
// guarantees the work lands somewhere else.
//
// H.264 is Pass 3d. Those blocks are counted and sized here so the card can
// prove the stream is alive, and nothing is decoded.

actor MJPEGDecoder {

    /// One decoder for the app. It holds no state, so sharing costs nothing
    /// and saves an actor per video card.
    static let shared = MJPEGDecoder()

    private var failures = 0

    /// Decodes one JPEG.
    ///
    /// - Returns: nil when the bytes are not a readable image. A dropped frame
    ///   is normal on a lossy stream and must never take the subscription with
    ///   it, so this reports rather than throws.
    func decode(_ data: Data, timestamp: Date) -> DecodedFrame? {
        guard !data.isEmpty else { return nil }

        // The marker check is not belt-and-braces, and ImageIO's own status is
        // not enough. Handed a JPEG whose scan runs out halfway, ImageIO still
        // reports the image complete and still returns a picture — the top half
        // of the frame, the rest grey. A viewer showing those looks like a
        // camera fault rather than the dropped packet it is.
        guard hasCompleteJPEGMarkers(data) else {
            failures += 1
            Log.client.debug("MJPEG frame of \(data.count) bytes is truncated, dropping")
            return nil
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            failures += 1
            Log.client.error("MJPEG frame of \(data.count) bytes did not decode (\(self.failures) so far)")
            return nil
        }

        return DecodedFrame(image: image, timestamp: timestamp, byteCount: data.count)
    }

    /// Whether the bytes begin with a JPEG SOI and end with its EOI.
    ///
    /// Non-JPEG payloads pass through: this decoder is only ever handed blocks
    /// a Block member called JPEG, and anything else should fail in ImageIO
    /// with ImageIO's own reasons rather than here.
    ///
    /// The EOI is looked for in a short tail rather than at the exact end,
    /// because an encoder may pad a frame to a byte or word boundary.
    private func hasCompleteJPEGMarkers(_ data: Data) -> Bool {
        guard data.count > 4 else { return false }
        let start = data.startIndex
        guard data[start] == 0xFF, data[start + 1] == 0xD8 else { return true }

        let tail = data.suffix(Self.endMarkerSearchWindow)
        var previous: UInt8 = 0
        for byte in tail {
            if previous == 0xFF && byte == 0xD9 { return true }
            previous = byte
        }
        return false
    }

    private static let endMarkerSearchWindow = 16

    /// Whether a compression code names something this decoder can read.
    ///
    /// Nodes spell it "JPEG" and "MJPEG"; a missing code on a stream that turns
    /// out to be JPEG is handled by the decode attempt failing harmlessly.
    nonisolated static func canDecode(compression: String?) -> Bool {
        guard let compression else { return false }
        let normalized = compression.lowercased()
        return normalized.contains("jpeg") || normalized.contains("jpg")
    }

    /// Whether a compression code names H.264, which Pass 3d will decode.
    nonisolated static func isH264(compression: String?) -> Bool {
        guard let compression else { return false }
        let normalized = compression.lowercased()
        return normalized.contains("264") || normalized.contains("avc")
    }
}
