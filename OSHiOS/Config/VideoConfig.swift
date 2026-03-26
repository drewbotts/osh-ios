import Foundation
import AVFoundation

// MARK: - VideoConfig
//
// Mirrors VideoEncoderConfig from Android.
// Defaults match Android defaults: 1280x720 @ 5 Mbps, 25 fps.

struct VideoPreset: Codable {
    var width: Int  = 1280
    var height: Int = 720
    var minBitrate: Int = 1_000  // kbits/s
    var maxBitrate: Int = 8_000  // kbits/s
    var selectedBitrate: Int = 5_000  // kbits/s  (matches Android default 5*1000*1000 bps)
}

struct VideoConfig: Codable {
    static let codecJPEG = "JPEG"
    static let codecH264 = "H264"

    var codec: String = codecH264
    var frameRate: Int = 5                   // lower default to reduce server load (Android default is 25)
    var selectedPreset: Int = 0
    var presets: [VideoPreset] = [VideoPreset()]

    var currentPreset: VideoPreset {
        guard selectedPreset < presets.count else { return VideoPreset() }
        return presets[selectedPreset]
    }

    /// Bitrate in bps (matches Android: selectedBitrate*1000)
    var bitrateBps: Int { currentPreset.selectedBitrate * 1_000 }

    /// Maps to an AVCaptureSession preset (best effort — exact resolution via format selection)
    var sessionPreset: AVCaptureSession.Preset {
        let w = currentPreset.width
        switch w {
        case 3840...: return .hd4K3840x2160
        case 1920...: return .hd1920x1080
        default:      return .hd1280x720
        }
    }
}
