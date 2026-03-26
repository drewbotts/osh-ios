import Foundation

// MARK: - AppConfig
//
// Central configuration persisted to UserDefaults.
// Matches AndroidSensorsConfig fields.

struct AppConfig: Codable {
    // OSH node connection
    var nodeURL: String      = "http://localhost:8181/sensorhub/api"
    var username: String     = "admin"
    var password: String     = "admin"

    // Device identity (mirrors uidExtension / deviceName / runDescription in AndroidSensorsConfig)
    var uidExtension: String  = ""
    var deviceName: String    = ""
    var runDescription: String = ""

    // Sensor enables (mirrors AndroidSensorsConfig booleans)
    var enableGPS: Bool            = true
    var enableOrientationQuat: Bool = true
    var enableOrientationEuler: Bool = true
    var enableBarometer: Bool      = true
    var enableAudioLevel: Bool     = true
    var enableVideoH264: Bool      = false

    // Video settings
    // iPhone AVFoundation actual output dimensions (landscape, no rotation applied):
    //   720p preset  (.hd1280x720)  → AVFoundation delivers 1280 × 720
    //   1080p preset (.hd1920x1080) → AVFoundation delivers 1920 × 1080
    // The actual dimensions used for encoding and the datastream schema are read
    // from the first CVPixelBuffer delivered by the capture session.
    var videoConfig: VideoConfig = VideoConfig()

    // MARK: UserDefaults persistence

    private static let defaultsKey = "AppConfig"

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
