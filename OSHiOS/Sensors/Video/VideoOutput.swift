import Foundation
import AVFoundation
import Combine

// MARK: - VideoOutput base
//
// Shared AVCaptureSession setup used by VideoOutputH264.
// Subclasses override handleSampleBuffer(_:) to apply their specific encoding.

class VideoOutput: NSObject, SensorModule, AVCaptureVideoDataOutputSampleBufferDelegate {

    // MARK: SensorModule (set by subclass init; recordDescription/recommendedEncoding
    //        updated lazily on first frame once actual pixel buffer dimensions are known)
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
    let codecName: String   // "H264" or "JPEG" — used when building schema on first frame

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

    /// Configures the AVCaptureSession.
    /// Called by SensorSession before datastream registration.
    /// Schema dimensions are updated lazily on the first frame in handleSampleBuffer.
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
        // matching the session preset (e.g. 1280×720 for .hd1280x720).
        // Schema dimensions are set lazily on the first frame.
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
        subject.send(obs)
    }
}
