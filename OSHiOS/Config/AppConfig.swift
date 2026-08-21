import Foundation

// MARK: - AppConfig
//
// Sensor-only configuration persisted to UserDefaults.
// Server connection settings (URL, credentials) are managed separately
// in AppSettingsStore / KeychainServerStore.
//
// Previous hardcoded defaults for reference (enter via Settings when testing):
//   URL:      http://localhost:8181/sensorhub/api
//   Username: admin
//   Password: admin

struct AppConfig: Codable {
    // Sensor enables
    var enableGPS: Bool             = true
    var enableOrientationQuat: Bool = true
    var enableOrientationEuler: Bool = true
    var enableBarometer: Bool       = true
    var enableAudioLevel: Bool      = true
    var enableVideoH264: Bool       = false

    // Video settings
    // iPhone AVFoundation actual output dimensions (landscape, no rotation applied):
    //   720p preset  (.hd1280x720)  → AVFoundation delivers 1280 × 720
    //   1080p preset (.hd1920x1080) → AVFoundation delivers 1920 × 1080
    // The actual dimensions used for encoding and the datastream schema are read
    // from the first CVPixelBuffer delivered by the capture session.
    var videoConfig: VideoConfig = VideoConfig()

    // MARK: Sample rates
    //
    // Seconds between samples. These feed the modules' averageSamplingPeriod,
    // which is what the node is told to expect, so changing one here changes
    // both the hardware rate and the registered datastream description.

    /// CMMotionManager device-motion interval, shared by both orientation outputs.
    var orientationInterval: Double = 0.1

    /// Audio level tap interval.
    var audioInterval: Double = 0.1

    // MARK: Behavior

    /// Start streaming shortly after launch when a server is selected.
    var autoStartOnLaunch: Bool = false

    // MARK: UserDefaults persistence

    private static let defaultsKey = "AppConfig"

    init() {}

    /// Every key is optional on the way in so that a config written by an
    /// earlier build still loads: a strict decode would throw on the first
    /// missing key and silently reset every sensor toggle the user had set.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppConfig()
        enableGPS              = try c.decodeIfPresent(Bool.self, forKey: .enableGPS)              ?? fallback.enableGPS
        enableOrientationQuat  = try c.decodeIfPresent(Bool.self, forKey: .enableOrientationQuat)  ?? fallback.enableOrientationQuat
        enableOrientationEuler = try c.decodeIfPresent(Bool.self, forKey: .enableOrientationEuler) ?? fallback.enableOrientationEuler
        enableBarometer        = try c.decodeIfPresent(Bool.self, forKey: .enableBarometer)        ?? fallback.enableBarometer
        enableAudioLevel       = try c.decodeIfPresent(Bool.self, forKey: .enableAudioLevel)       ?? fallback.enableAudioLevel
        enableVideoH264        = try c.decodeIfPresent(Bool.self, forKey: .enableVideoH264)        ?? fallback.enableVideoH264
        videoConfig            = try c.decodeIfPresent(VideoConfig.self, forKey: .videoConfig)     ?? fallback.videoConfig
        orientationInterval    = try c.decodeIfPresent(Double.self, forKey: .orientationInterval)  ?? fallback.orientationInterval
        audioInterval          = try c.decodeIfPresent(Double.self, forKey: .audioInterval)        ?? fallback.audioInterval
        autoStartOnLaunch      = try c.decodeIfPresent(Bool.self, forKey: .autoStartOnLaunch)      ?? fallback.autoStartOnLaunch
    }

    static func load() -> AppConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
