import SwiftUI

// MARK: - PreviewSupport
//
// Stub data for #Preview blocks. Previews must not touch hardware or the
// network, so every view that needs live state gets a hand-built
// SensorLiveState here instead of a running SensorSession.
//
// The stubs are built from the *real* schema helpers rather than from
// hand-written records: a preview that renders a fabricated schema would stop
// catching the case where a schema change breaks a card.

enum PreviewSupport {

    static let localFrame = "urn:osh:ios:preview#LOCAL_FRAME"

    // MARK: Sensors

    static func gpsSensor() -> SensorLiveState {
        let schema = GeoPosHelper.newLocationRecord(name: "gps_data",
                                                    localFrameURI: localFrame)
        var state = SensorLiveState(id: "gps_data",
                                    displayName: schema.label ?? "gps_data",
                                    schema: schema)
        let base = Date().addingTimeInterval(-60)
        for index in 0..<40 {
            let drift = Double(index) * 0.00012
            let scalars: [Double] = [
                base.addingTimeInterval(Double(index)).timeIntervalSince1970,
                34.72501 + drift,
                -86.58302 - drift,
                190.4 + Double(index) * 0.3
            ]
            if let parsed = try? SchemaWalker.parsedObservation(datastreamId: "gps_data",
                                                                record: schema,
                                                                scalars: scalars) {
                state.append(parsed, at: base.addingTimeInterval(Double(index)))
            }
        }
        state.stats.observations = 40
        state.stats.bytes = 40 * 96
        state.stats.rate = 1.0
        state.availability = .active
        return state
    }

    static func eulerSensor() -> SensorLiveState {
        let schema = GeoPosHelper.newEulerOrientationRecord(name: "euler_orientation_data",
                                                            localFrameURI: localFrame)
        var state = SensorLiveState(id: "euler_orientation_data",
                                    displayName: schema.label ?? "euler_orientation_data",
                                    schema: schema)
        let base = Date().addingTimeInterval(-6)
        for index in 0..<60 {
            let phase = Double(index) / 8.0
            let scalars: [Double] = [
                base.addingTimeInterval(Double(index) * 0.1).timeIntervalSince1970,
                180 + 40 * sin(phase),
                12 * cos(phase),
                -6 * sin(phase * 1.7)
            ]
            if let parsed = try? SchemaWalker.parsedObservation(datastreamId: "euler_orientation_data",
                                                                record: schema,
                                                                scalars: scalars) {
                state.append(parsed, at: base.addingTimeInterval(Double(index) * 0.1))
            }
        }
        state.stats.observations = 600
        state.stats.bytes = 600 * 84
        state.stats.rate = 10
        state.availability = .active
        return state
    }

    static func videoSensor() -> SensorLiveState {
        let (schema, encoding) = VideoCamHelper.newVideoOutputCODEC(name: "camera0_H264",
                                                                    width: 1280,
                                                                    height: 720,
                                                                    codec: "H264")
        var state = SensorLiveState(id: "camera0_H264",
                                    displayName: schema.label ?? "camera0_H264",
                                    schema: schema)
        let observation = Observation(datastreamName: "camera0_H264",
                                      payload: .video(timestamp: Date().timeIntervalSince1970,
                                                      frame: Data(repeating: 0, count: 42_000)))
        if let parsed = try? observation.parsed(schema: schema, encoding: encoding) {
            state.append(parsed)
        }
        state.stats.observations = 120
        state.stats.bytes = 120 * 42_000
        state.stats.rate = 5
        return state
    }

    static func unavailableSensor() -> SensorLiveState {
        let schema = GeoPosHelper.newQuatOrientationRecord(name: "quat_orientation_data",
                                                           localFrameURI: localFrame)
        var state = SensorLiveState(id: "quat_orientation_data",
                                    displayName: schema.label ?? "quat_orientation_data",
                                    schema: schema)
        state.markUnavailable("Device motion not available")
        return state
    }

    static let videoStats = VideoStats(encodedFPS: 4.8,
                                       bitrateKbps: 4_820,
                                       droppedFrames: 3,
                                       width: 1280,
                                       height: 720)

    // MARK: Track

    static func track() -> [TrackPoint] {
        let base = Date().addingTimeInterval(-300)
        return (0..<120).map { index in
            let drift = Double(index) * 0.00025
            return TrackPoint(latitude: 34.72501 + drift,
                              longitude: -86.58302 - drift * 0.6,
                              altitude: 190 + Double(index) * 0.2,
                              horizontalAccuracy: 8,
                              timestamp: base.addingTimeInterval(Double(index) * 2))
        }
    }

    // MARK: Node

    static let datastreams: [DatastreamSummary] = [
        DatastreamSummary(id: "ds01", name: "gps_data", outputName: "gps_data",
                          systemId: "sys1", formats: ["application/swe+json"], live: true),
        DatastreamSummary(id: "ds02", name: "camera0_H264", outputName: "camera0_H264",
                          systemId: "sys1", formats: ["application/swe+binary"], live: true)
    ]

    static let systems: [SystemSummary] = [
        SystemSummary(id: "sys1", uid: "urn:osh:ios:preview", name: "Preview iPhone",
                      description: "Stub system", type: "PhysicalSystem")
    ]

    // MARK: Logs

    static func logEntries() -> [LogEntry] {
        let base = Date().addingTimeInterval(-30)
        let samples: [(LogLevel, String, String)] = [
            (.info,  "session", "Building sensor modules…"),
            (.info,  "api",     "Registering system…"),
            (.debug, "client",  "GET /systems → 200"),
            (.info,  "video",   "Capture dimensions 1280x720 — schema updated"),
            (.error, "api",     "Batch POST failed for gps_data: The request timed out."),
            (.info,  "sensors", "Location authorized — starting updates")
        ]
        return samples.enumerated().map { index, sample in
            LogEntry(sequence: UInt64(index + 1),
                     date: base.addingTimeInterval(Double(index) * 3),
                     level: sample.0,
                     subsystem: Log.subsystem,
                     category: sample.1,
                     message: sample.2)
        }
    }
}

// MARK: - Preview environment

extension View {
    /// Injects the three environment objects every tab expects. Only for
    /// previews — the app builds its own in osh_iosApp.
    func previewEnvironment() -> some View {
        self
            .environmentObject(AppSettingsStore())
            .environmentObject(NodeConnectionStore())
            .environmentObject(SensorSession())
            .environmentObject(ActivityTracker.shared)
            .environmentObject(TabRouter())
    }
}
