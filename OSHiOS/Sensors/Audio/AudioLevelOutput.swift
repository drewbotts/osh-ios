import Foundation
import AVFoundation
import Combine

// MARK: - AudioLevelOutput
//
// Captures ambient sound level from the microphone using AVAudioEngine.
// Publishes RMS dB and peak dB at ~10 Hz (0.1 s buffer tap).
// Does NOT store or transmit raw audio samples — dB scalars only.
//
// SWE schema field order (must match values array order exactly):
//   0: time     — Unix epoch seconds → ISO 8601 string
//   1: rmsdB    — RMS level in dB (float, typically -160..0)
//   2: peakdB   — Peak level in dB (float, typically -160..0)
//
// Microphone permission must be granted before start() is called.
// If the engine fails to start (permission denied, hardware unavailable),
// start() throws SensorError.unavailable so the session continues without audio.

final class AudioLevelOutput: SensorModule {
    let outputName = "audio_level"
    let recordDescription: DataRecord
    let recommendedEncoding: BinaryEncoding
    let averageSamplingPeriod: Double = 0.1

    private let subject = PassthroughSubject<Observation, Never>()
    var publisher: AnyPublisher<Observation, Never> { subject.eraseToAnyPublisher() }

    private let engine = AVAudioEngine()
    private var isRunning = false

    // MARK: Init

    init() {
        self.recordDescription = DataRecord(
            definition: "http://sensorml.com/ont/swe/property/SoundLevel",
            label: "Audio Level",
            name: "audio_level",
            fields: [
                DataField(name: "time", component: TimeStamp(
                    definition: "http://www.opengis.net/def/property/OGC/0/SamplingTime",
                    label: "Sampling Time",
                    refFrame: "http://www.opengis.net/def/trs/BIPM/0/UTC",
                    uomHref: "http://www.opengis.net/def/uom/ISO-8601/0/Gregorian"
                )),
                DataField(name: "rmsdB", component: Quantity(
                    definition: "http://sensorml.com/ont/swe/property/SoundPressureLevel",
                    label: "RMS Sound Level",
                    uom: "dB",
                    dataType: .float
                )),
                DataField(name: "peakdB", component: Quantity(
                    definition: "http://sensorml.com/ont/swe/property/SoundPressureLevel",
                    label: "Peak Sound Level",
                    uom: "dB",
                    dataType: .float
                ))
            ]
        )
        self.recommendedEncoding = BinaryEncoding(fields: [
            BinaryFieldEncoding(ref: "/time",   type: .scalar(.double)),
            BinaryFieldEncoding(ref: "/rmsdB",  type: .scalar(.float)),
            BinaryFieldEncoding(ref: "/peakdB", type: .scalar(.float))
        ])
    }

    // MARK: SensorModule

    func start() throws {
        // Check microphone permission
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            if status == .notDetermined {
                // Request permission asynchronously — caller should retry after grant
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
            throw SensorError.unavailable("Microphone permission not granted")
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0 else {
            throw SensorError.unavailable("Audio input not available")
        }

        // Buffer size for ~0.1 s
        let bufferSize = AVAudioFrameCount(format.sampleRate * averageSamplingPeriod)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.processBuffer(buffer)
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw SensorError.unavailable("AVAudioEngine failed to start: \(error.localizedDescription)")
        }

        isRunning = true

        // Handle audio session interruptions (phone calls, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        NotificationCenter.default.removeObserver(self)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - Private

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        let samples = channelData[0]

        // Compute RMS
        var sumSquares: Float = 0
        var peak: Float = 0
        for i in 0..<frameLength {
            let s = samples[i]
            sumSquares += s * s
            let absSample = abs(s)
            if absSample > peak { peak = absSample }
        }
        let rms = sqrt(sumSquares / Float(frameLength))

        // Convert to dB (clamp to avoid -inf)
        let minLinear: Float = 1e-8
        let rmsdB  = 20.0 * log10(max(rms,  minLinear))
        let peakdB = 20.0 * log10(max(peak, minLinear))

        let scalars: [Double] = [
            Date().timeIntervalSince1970,
            Double(rmsdB),
            Double(peakdB)
        ]
        subject.send(Observation(datastreamName: outputName, payload: .scalar(scalars)))
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        if type == .ended,
           let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt,
           AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
            try? engine.start()
        }
    }
}
