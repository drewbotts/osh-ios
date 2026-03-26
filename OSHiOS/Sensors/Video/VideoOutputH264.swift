import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia
import Combine

// MARK: - VideoOutputH264
//
// iOS port of AndroidCameraOutputH264.
//
// Android settings replicated here:
//   codec            : MIMETYPE_VIDEO_AVC → kCMVideoCodecType_H264
//   bitrate mode     : VBR
//   KEY_I_FRAME_INTERVAL : 1 second
//   color format     : YUV420SemiPlanar (NV12)
//   SPS/PPS          : prepended to every keyframe (Annex B)
//   output format    : raw NAL units in Annex B (\x00\x00\x00\x01 start code)
//
// VideoToolbox emits AVCC (4-byte big-endian length-prefixed NAL units).
// We convert to Annex B: replace each 4-byte length prefix with \x00\x00\x00\x01.
// SPS/PPS extracted from format description on first keyframe and prepended to
// every subsequent keyframe — matching Android's codecInfoData prepend pattern.

final class VideoOutputH264: VideoOutput {

    private var compressionSession: VTCompressionSession?
    private var spsPpsData: Data?
    private var frameCount: Int64 = 0
    private var hasDimensionsLogged = false
    private var encoderInitialized = false

    static let codecName = "H264"

    init(config: VideoConfig) {
        let preset = config.currentPreset
        let codec = VideoOutputH264.codecName   // capture static before super.init
        let (schema, encoding) = VideoCamHelper.newVideoOutputCODEC(
            name: "camera0_\(codec)",
            width: preset.width,
            height: preset.height,
            codec: codec
        )
        super.init(
            outputName: "camera0_\(codec)",
            schema: schema,
            encoding: encoding,
            config: config,
            codecName: codec
        )
    }

    // MARK: SensorModule

    override func start() throws {
        // Encoder is initialized lazily on first frame — actual pixel buffer
        // dimensions are not known until AVFoundation delivers the first buffer.
        try super.start()
    }

    override func stop() {
        super.stop()
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
        spsPpsData = nil
        frameCount = 0
        hasDimensionsLogged = false
        encoderInitialized = false
    }

    // MARK: Encoder setup

    /// Called on the first frame to initialize VTCompressionSession with the
    /// actual pixel buffer dimensions and update the datastream schema to match.
    private func initializeEncoderIfNeeded(pixelBuffer: CVPixelBuffer) {
        guard !encoderInitialized else { return }
        encoderInitialized = true

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        // One-time log so dimensions can be confirmed during development
        if !hasDimensionsLogged {
            hasDimensionsLogged = true
            print("[VideoOutputH264] First frame dimensions: \(w)×\(h) (CVPixelBuffer)")
        }

        // Update datastream schema to match the actual pixel buffer dimensions
        let (schema, enc) = VideoCamHelper.newVideoOutputCODEC(
            name: outputName, width: w, height: h, codec: Self.codecName)
        recordDescription   = schema
        recommendedEncoding = enc

        // Create compression session sized to actual pixel buffer dimensions
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width:     Int32(w),
            height:    Int32(h),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session = session else {
            print("[VideoOutputH264] VTCompressionSessionCreate failed: \(status)")
            return
        }
        self.compressionSession = session

        // kVTCompressionPropertyKey_AllowFrameReordering = false — critical for live streaming
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)

        // Keyframe interval = 1 second (matches Android KEY_I_FRAME_INTERVAL = 1)
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: config.frameRate as CFTypeRef)

        // Bitrate (VBR — VideoToolbox default)
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_AverageBitRate,
                             value: config.bitrateBps as CFTypeRef)

        // H.264 profile: Baseline for maximum compatibility with streaming clients
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Baseline_AutoLevel)

        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    // MARK: Frame handler

    override func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        initializeEncoderIfNeeded(pixelBuffer: pixelBuffer)

        guard let session = compressionSession else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let wallTime = wallClockTimestamp(from: sampleBuffer)

        var flags = VTEncodeInfoFlags()
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: &flags
        ) { [weak self] status, _, encodedBuffer in
            guard let self = self, status == noErr,
                  let encodedBuffer = encodedBuffer else { return }
            self.processEncodedSample(encodedBuffer, wallTime: wallTime)
        }
    }

    // MARK: AVCC → Annex B conversion

    private func processEncodedSample(_ sampleBuffer: CMSampleBuffer, wallTime: Double) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // Determine if this is a keyframe by inspecting sample attachments
        let isKeyFrame: Bool
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[CFString: Any]],
           let first = attachmentsArray.first {
            // kCMSampleAttachmentKey_NotSync is absent (or false) for keyframes
            isKeyFrame = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        } else {
            isKeyFrame = true  // assume keyframe when no attachment info
        }

        // Extract SPS/PPS from format description on the first keyframe
        if isKeyFrame, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            spsPpsData = extractSpsPps(from: formatDesc)
        }

        // Walk the AVCC block buffer and convert NAL units to Annex B
        var annexBData = Data()
        if isKeyFrame, let spsPps = spsPpsData {
            annexBData.append(spsPps)
        }

        let totalLen = CMBlockBufferGetDataLength(dataBuffer)
        var offset = 0

        while offset < totalLen {
            // Read 4-byte big-endian NAL unit length
            var nalLengthBE: UInt32 = 0
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: offset,
                                       dataLength: 4, destination: &nalLengthBE)
            let nalLength = Int(CFSwapInt32BigToHost(nalLengthBE))
            offset += 4

            // Annex B start code
            annexBData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])

            // NAL payload
            var nalBytes = [UInt8](repeating: 0, count: nalLength)
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: offset,
                                       dataLength: nalLength, destination: &nalBytes)
            annexBData.append(contentsOf: nalBytes)
            offset += nalLength
        }

        guard !annexBData.isEmpty else { return }
        sendFrame(timestamp: wallTime, data: annexBData)
    }

    /// Extract SPS and PPS parameter sets from a format description.
    /// Returns them concatenated as Annex B bytes (start code + NAL per set).
    private func extractSpsPps(from formatDesc: CMFormatDescription) -> Data? {
        var result = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        // Query total number of parameter sets (includes both SPS and PPS)
        var totalCount = 0
        var nalHeaderLength: Int32 = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &totalCount,
            nalUnitHeaderLengthOut: &nalHeaderLength
        )

        for i in 0 ..< totalCount {
            var ptr: UnsafePointer<UInt8>?
            var size: Int = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc,
                parameterSetIndex: i,
                parameterSetPointerOut: &ptr,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            if status == noErr, let ptr = ptr, size > 0 {
                result.append(contentsOf: startCode)
                result.append(ptr, count: size)
            }
        }

        return result.isEmpty ? nil : result
    }
}
