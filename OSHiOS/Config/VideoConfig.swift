import Foundation
import AVFoundation

// MARK: - VideoConfig
//
// Mirrors VideoEncoderConfig from Android.
// Defaults match Android defaults: 1280x720 @ 5 Mbps, 25 fps.

struct VideoPreset: Codable, Equatable {
    var width: Int  = 1280
    var height: Int = 720
    var minBitrate: Int = 1_000  // kbits/s
    var maxBitrate: Int = 8_000  // kbits/s
    var selectedBitrate: Int = 5_000  // kbits/s  (matches Android default 5*1000*1000 bps)

    /// Human-readable name for the picker, derived rather than stored so it
    /// cannot disagree with the dimensions.
    var displayName: String { "\(height)p" }

    /// 1280×720 — the default, unchanged from the original single preset.
    static let hd720 = VideoPreset()

    /// 1920×1080. A larger frame needs more bits to look the same, hence the
    /// higher floor and ceiling.
    static let hd1080 = VideoPreset(width: 1920, height: 1080,
                                    minBitrate: 2_000, maxBitrate: 16_000,
                                    selectedBitrate: 8_000)

    static let standard: [VideoPreset] = [hd720, hd1080]
}

struct VideoConfig: Codable {
    static let codecJPEG = "JPEG"
    static let codecH264 = "H264"

    /// Codecs the encoder can produce. JPEG is defined in the SWE helpers but
    /// no encoder path exists for it yet, so the picker offers H.264 alone.
    static let availableCodecs = [codecH264]

    static let availableFrameRates = [1, 2, 5, 10, 15, 25]

    var codec: String = codecH264
    var frameRate: Int = 5                   // lower default to reduce server load (Android default is 25)
    var selectedPreset: Int = 0
    var presets: [VideoPreset] = VideoPreset.standard

    init() {}

    /// Tolerant decode, for the same reason AppConfig's is: a config written by
    /// an earlier build stored a single preset, and rejecting it would reset
    /// every video setting the user had chosen. The stored preset keeps index 0
    /// so `selectedPreset` still means what it meant when it was written.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        codec          = try c.decodeIfPresent(String.self, forKey: .codec) ?? Self.codecH264
        frameRate      = try c.decodeIfPresent(Int.self, forKey: .frameRate) ?? 5
        selectedPreset = try c.decodeIfPresent(Int.self, forKey: .selectedPreset) ?? 0

        var stored = try c.decodeIfPresent([VideoPreset].self, forKey: .presets) ?? []
        if stored.isEmpty {
            stored = VideoPreset.standard
        } else if stored.count < VideoPreset.standard.count {
            stored.append(contentsOf: VideoPreset.standard.dropFirst(stored.count))
        }
        presets = stored
        selectedPreset = min(max(selectedPreset, 0), presets.count - 1)
    }

    var currentPreset: VideoPreset {
        guard presets.indices.contains(selectedPreset) else { return VideoPreset() }
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
