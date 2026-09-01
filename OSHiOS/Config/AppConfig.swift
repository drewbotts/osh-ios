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

    // MARK: Map layers

    /// Which layers the common operating picture draws. Persisted because a
    /// user who turned tracks off did so for a reason and should not have to do
    /// it again on every launch.
    var mapLayers: MapLayers = MapLayers()

    // MARK: Video wall

    /// Whether node video tiles start playing on their own.
    ///
    /// Tri-state rather than a Bool: the default is "on WiFi only", which needs
    /// a value distinct from a user who has explicitly said always or never.
    var videoAutoplay: VideoAutoplay = .wifiOnly

    // MARK: Commands

    /// Degrees per D-pad press on the PTZ controller.
    var ptzStepDegrees: Double = 5

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
        mapLayers              = try c.decodeIfPresent(MapLayers.self, forKey: .mapLayers)         ?? fallback.mapLayers
        videoAutoplay          = try c.decodeIfPresent(VideoAutoplay.self, forKey: .videoAutoplay) ?? fallback.videoAutoplay
        ptzStepDegrees         = try c.decodeIfPresent(Double.self, forKey: .ptzStepDegrees)       ?? fallback.ptzStepDegrees
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


// MARK: - MapLayers

/// What the common operating picture draws.
///
/// Every field defaults to on — a map that opened with half its layers hidden
/// would look like a broken node rather than a configured view — with one
/// exception. `targetHistory` draws every past target rather than the current
/// one, which is a question the user has to ask.
struct MapLayers: Codable, Equatable, Sendable {
    var thisDevice = true
    var nodeSystems = true
    var tracks = true
    var bearingLines = true
    var labels = true
    /// Group markers that are too close together to tell apart.
    var clusterMarkers = true
    /// Past target designations, as dots with no lines. Off by default: the
    /// live target is the answer to "where is it", and twenty of them is the
    /// answer to a different question.
    var targetHistory = false
    /// The old Node-map "Live" switch: whether node systems hold subscriptions.
    var liveUpdates = true

    init() {}

    /// Tolerant like AppConfig's own, and for the same reason.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = MapLayers()
        thisDevice   = try c.decodeIfPresent(Bool.self, forKey: .thisDevice)   ?? fallback.thisDevice
        nodeSystems  = try c.decodeIfPresent(Bool.self, forKey: .nodeSystems)  ?? fallback.nodeSystems
        tracks       = try c.decodeIfPresent(Bool.self, forKey: .tracks)       ?? fallback.tracks
        bearingLines = try c.decodeIfPresent(Bool.self, forKey: .bearingLines) ?? fallback.bearingLines
        labels       = try c.decodeIfPresent(Bool.self, forKey: .labels)       ?? fallback.labels
        targetHistory = try c.decodeIfPresent(Bool.self, forKey: .targetHistory) ?? fallback.targetHistory
        clusterMarkers = try c.decodeIfPresent(Bool.self, forKey: .clusterMarkers) ?? fallback.clusterMarkers
        liveUpdates  = try c.decodeIfPresent(Bool.self, forKey: .liveUpdates)  ?? fallback.liveUpdates
    }
}

// MARK: - VideoAutoplay

/// When a video-wall tile starts playing without being asked.
///
/// The default is WiFi-only because the wall opens every MJPEG stream it can
/// and a cellular link should never be spent on video the user did not request.
enum VideoAutoplay: String, Codable, CaseIterable, Sendable {
    case always
    case wifiOnly
    case never

    var label: String {
        switch self {
        case .always:   return "Always"
        case .wifiOnly: return "On WiFi"
        case .never:    return "Never"
        }
    }
}
