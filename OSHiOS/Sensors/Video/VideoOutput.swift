import Foundation
import AVFoundation
import Combine

// MARK: - VideoOutput base
//
// Shared AVCaptureSession setup used by VideoOutputH264.
// Subclasses override handleSampleBuffer(_:) to apply their specific encoding.
//
// Frames do NOT travel through ObservationPublisher. A single H.264 frame is
// orders of magnitude larger than a scalar record, so putting frames in the
// scalar ring buffer or batch array would evict real sensor data and add
// latency. Instead SensorSession installs `directPoster`, which POSTs each frame
// straight to /datastreams/{id}/observations, and an in-flight guard drops any
// frame that arrives while the previous POST is still running — dropping the
// newest frame is always better than queueing an ever-growing backlog of stale
// ones on a slow link.

// @unchecked Sendable: recordDescription / recommendedEncoding are mutated only
// in configure(), which runs on the main actor before capture starts; the
// capture-queue callbacks read them but never write. directPoster is likewise
// assigned before start(). The remaining members are `let`s owned by AVFoundation.
class VideoOutput: NSObject, SensorModule, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    // MARK: SensorModule (set by subclass init; recordDescription/recommendedEncoding
    //        are rebuilt in configure() from the device's real active format)
    let outputName: String
    var recordDescription: DataRecord
    var recommendedEncoding: BinaryEncoding
    let averageSamplingPeriod: Double

    // MARK: Combine
    private let subject = PassthroughSubject<Observation, Never>()
    var publisher: AnyPublisher<Observation, Never> { subject.eraseToAnyPublisher() }

    // MARK: Capture session
    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "osh.video.capture", qos: .userInitiated)

    let config: VideoConfig
    let codecName: String   // "H264" or "JPEG" — used when building the schema

    // MARK: Direct posting
    //
    // Set by SensorSession to a closure that POSTs one frame to the OSH node.
    // Assigned before start(); nil means frames are only published on `publisher`
    // (used by the UI for a liveness indicator).
    var directPoster: (@Sendable (Observation) async -> Void)?

    /// Number of frames dropped because the previous POST had not finished.
    var droppedFrames: Int { frameGate.dropped }

    private let frameGate = FrameGate()

    // MARK: Init

    init(outputName: String,
         schema: DataRecord,
         encoding: BinaryEncoding,
         config: VideoConfig,
         codecName: String) {
        self.outputName = outputName
        self.recordDescription = schema
        self.recommendedEncoding = encoding
        self.config = config
        self.codecName = codecName
        self.averageSamplingPeriod = 1.0 / Double(config.frameRate)
        super.init()
    }

    // MARK: SensorModule

    /// Configures the AVCaptureSession and resolves the real capture dimensions.
    /// Called by SensorSession before datastream registration, so the datastream
    /// is registered with the size the camera will actually deliver.
    func configure() throws {
        try configureSession()
    }

    func start() throws {
        captureSession.startRunning()
    }

    func stop() {
        captureSession.stopRunning()
    }

    // MARK: Session setup

    private func configureSession() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = config.sessionPreset

        // Camera input
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw SensorError.unavailable("No back camera available")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw SensorError.configurationError("Cannot add camera input")
        }
        captureSession.addInput(input)

        // The session preset is a request, not a guarantee — the device picks an
        // activeFormat that may differ from the preset's nominal size. Read the
        // real dimensions now and rebuild the schema/encoding from them, so
        // datastream registration advertises the size the encoder will actually
        // produce rather than the VideoConfig preset's guess.
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        if dimensions.width > 0 && dimensions.height > 0 {
            let (schema, encoding) = VideoCamHelper.newVideoOutputCODEC(
                name: outputName,
                width: Int(dimensions.width),
                height: Int(dimensions.height),
                codec: codecName
            )
            recordDescription   = schema
            recommendedEncoding = encoding
            Log.video.info("Capture dimensions \(dimensions.width)x\(dimensions.height) — schema updated")
        } else {
            Log.video.error("activeFormat reported no dimensions — keeping preset schema")
        }

        // Configure frame rate
        try device.lockForConfiguration()
        let targetFPS = CMTime(value: 1, timescale: CMTimeScale(config.frameRate))
        let supportedRanges = device.activeFormat.videoSupportedFrameRateRanges
        if supportedRanges.contains(where: { $0.maxFrameDuration <= targetFPS }) {
            device.activeVideoMinFrameDuration = targetFPS
            device.activeVideoMaxFrameDuration = targetFPS
        }
        device.unlockForConfiguration()

        // Video data output — kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange = NV12
        // Matches Android's COLOR_FormatYUV420SemiPlanar (NV12)
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)

        guard captureSession.canAddOutput(videoOutput) else {
            throw SensorError.configurationError("Cannot add video output")
        }
        captureSession.addOutput(videoOutput)

        // No rotation applied — AVFoundation delivers landscape pixel buffers
        // matching the device's active format, whose dimensions we read above.
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        handleSampleBuffer(sampleBuffer)
    }

    // MARK: Override point for subclasses

    func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        fatalError("Subclasses must override handleSampleBuffer(_:)")
    }

    // MARK: Helpers

    /// Wall-clock Unix timestamp from a CMSampleBuffer presentation timestamp.
    /// Mirrors Android: systemTimeOffset + sensorTimeMillis / 1000
    func wallClockTimestamp(from sampleBuffer: CMSampleBuffer) -> Double {
        // pts is device uptime; we offset to wall clock the same way Android does.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if pts == .invalid { return Date().timeIntervalSince1970 }
        // Device uptime → wall clock: same approach as Android's systemTimeOffset pattern.
        let uptimeSecs = pts.seconds
        let wallOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        return wallOffset + uptimeSecs
    }

    func sendFrame(timestamp: Double, data: Data) {
        let obs = Observation(
            datastreamName: outputName,
            payload: .video(timestamp: timestamp, frame: data)
        )

        // Published for the UI's liveness indicator only — ObservationPublisher
        // deliberately does not subscribe to binary-block modules.
        subject.send(obs)

        guard let poster = directPoster else { return }

        // In-flight guard: at most one frame POST is outstanding at a time.
        // A slow link would otherwise spawn a task per frame and pile up
        // megabytes of stale frames in memory.
        guard frameGate.tryEnter() else { return }
        Task {
            await poster(obs)
            self.frameGate.leave()
        }
    }
}

// MARK: - FrameGate

/// One-slot mutual-exclusion gate for outbound frame POSTs, plus a drop counter.
/// Lock-based rather than actor-based because sendFrame(_:) runs synchronously on
/// the capture queue and must decide to drop *without* suspending.
private final class FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = false
    private var droppedCount = 0

    /// Returns true if the caller took the slot; false means a POST is already
    /// running and this frame should be dropped (the drop is counted).
    func tryEnter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if inFlight {
            droppedCount += 1
            return false
        }
        inFlight = true
        return true
    }

    func leave() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }

    var dropped: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedCount
    }
}
