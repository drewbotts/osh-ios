import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import VideoToolbox

// MARK: - H264NALUnit

/// One H.264 Network Abstraction Layer unit, without its start code.
struct H264NALUnit: Equatable, Sendable {
    let payload: Data

    /// `nal_unit_type` — the low five bits of the header byte.
    var type: UInt8 { (payload.first ?? 0) & 0x1F }

    static let typeSlice: UInt8 = 1
    static let typeIDR: UInt8 = 5
    static let typeSEI: UInt8 = 6
    static let typeSPS: UInt8 = 7
    static let typePPS: UInt8 = 8
}

// MARK: - H264AccessUnit

/// Splits one observation's block into its NAL units.
enum H264AccessUnit {

    /// Annex B first — `00 00 01` and `00 00 00 01` start codes, which is what
    /// the node's cameras and this app's own encoder emit. A block with no
    /// start code at all is tried as AVCC, four-byte big-endian lengths, and
    /// accepted only when those lengths tile the block exactly; anything else
    /// is not H.264 the decoder can be handed.
    static func nalUnits(in data: Data) -> [H264NALUnit] {
        let bytes = [UInt8](data)
        let annexB = splitAnnexB(bytes)
        if !annexB.isEmpty { return annexB }
        return splitAVCC(bytes)
    }

    private static func splitAnnexB(_ bytes: [UInt8]) -> [H264NALUnit] {
        var starts: [Int] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        guard !starts.isEmpty else { return [] }

        var units: [H264NALUnit] = []
        for (index, start) in starts.enumerated() {
            // A unit runs to the next start code, less the code itself and any
            // zero bytes ahead of it: the fourth byte of a long start code and
            // `trailing_zero_8bits` both belong to the framing, not the unit.
            var end = index + 1 < starts.count ? starts[index + 1] - 3 : bytes.count
            while end > start, bytes[end - 1] == 0 { end -= 1 }
            guard end > start else { continue }
            units.append(H264NALUnit(payload: Data(bytes[start ..< end])))
        }
        return units
    }

    private static func splitAVCC(_ bytes: [UInt8]) -> [H264NALUnit] {
        var units: [H264NALUnit] = []
        var i = 0
        while i + 4 <= bytes.count {
            let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16
                       | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let start = i + 4
            guard length > 0, start + length <= bytes.count else { return [] }
            units.append(H264NALUnit(payload: Data(bytes[start ..< start + length])))
            i = start + length
        }
        return i == bytes.count ? units : []
    }
}

// MARK: - H264Decoder
//
// Annex-B H.264 access units in, CGImages out, through VideoToolbox.
//
// Unlike MJPEG this is stateful, which is why there is one decoder per
// datastream rather than one for the app. A P-frame is a diff against pictures
// the decoder has already seen, so a stream joined mid-GOP is not drawable
// until its next keyframe, and a change of SPS/PPS means a new format
// description and, usually, a new decompression session.
//
// The sources this has to serve prepend SPS and PPS to every IDR — the node's
// cameras do, and so does this app's own encoder — so a fresh subscriber is
// never more than one GOP from a picture and nothing has to be fetched out of
// band. Parameter sets arriving in their own observation are kept for the
// keyframe that follows.
//
// Decoding is synchronous: with the asynchronous flag left clear, VideoToolbox
// runs the output handler before DecodeFrame returns, which keeps the whole
// thing a plain function call inside the actor. Baseline and Main profile
// streams without B-frames — every camera seen so far — need no reordering,
// so the picture that comes back is the frame that went in.
//
// An actor for the same reason MJPEGDecoder is: a SystemLiveSession is
// @MainActor, and a decode plus a BGRA conversion per frame at 30 fps is
// exactly the work that must not happen there.

actor H264Decoder {

    // MARK: Types

    /// Owns one VTDecompressionSession and invalidates it when released.
    ///
    /// A class rather than the bare session, so that dropping the decoder —
    /// the actor's deinit is nonisolated and may not touch its state — still
    /// tears the session down through ordinary ARC.
    private final class SessionHandle {
        let session: VTDecompressionSession
        init(_ session: VTDecompressionSession) { self.session = session }
        deinit { VTDecompressionSessionInvalidate(session) }
    }

    /// What one synchronous decode produced.
    ///
    /// @unchecked Sendable: VideoToolbox's output handler is @Sendable, and
    /// with asynchronous decompression left off it runs to completion before
    /// DecodeFrame returns — so the box is written once, on the calling thread,
    /// and read after, with no concurrent access the compiler could see.
    private final class DecodeOutput: @unchecked Sendable {
        var status: OSStatus = noErr
        var image: CGImage?
    }

    // MARK: State

    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var session: SessionHandle?

    /// True until an IDR has been decoded on the current session. Slices that
    /// arrive before one are dropped rather than handed to the decoder, which
    /// would otherwise paint grey smears against references it never had.
    private var awaitingKeyframe = true

    private(set) var decodedFrames = 0
    private(set) var droppedFrames = 0
    private var failures = 0

    init() {}

    // MARK: Decoding

    /// Decodes one access unit.
    ///
    /// - Returns: nil when there is nothing to draw yet — a slice before the
    ///   first keyframe, an observation that carried only parameter sets, or a
    ///   frame VideoToolbox refused. None of those may take the stream down, so
    ///   this reports rather than throws.
    func decode(_ data: Data, timestamp: Date) -> DecodedFrame? {
        let units = H264AccessUnit.nalUnits(in: data)
        guard !units.isEmpty else {
            noteFailure("block of \(data.count) bytes holds no NAL units")
            return nil
        }

        var newSPS: Data?
        var newPPS: Data?
        var slices: [H264NALUnit] = []
        var isKeyframe = false

        for unit in units {
            switch unit.type {
            case H264NALUnit.typeSPS:
                newSPS = unit.payload
            case H264NALUnit.typePPS:
                newPPS = unit.payload
            case H264NALUnit.typeIDR:
                isKeyframe = true
                slices.append(unit)
            case H264NALUnit.typeSlice, H264NALUnit.typeSEI:
                slices.append(unit)
            default:
                // Access unit delimiters, filler, end-of-sequence: framing the
                // sample buffer does not need and the decoder does not want.
                continue
            }
        }

        if let newSPS, let newPPS {
            if newSPS != sps || newPPS != pps || session == nil {
                configure(sps: newSPS, pps: newPPS)
            }
        } else if session == nil, let sps, let pps {
            // A session lost to the system — see the invalid-session case
            // below — is rebuilt from the parameter sets already held.
            configure(sps: sps, pps: pps)
        }

        guard !slices.isEmpty else { return nil }
        guard let session, let formatDescription else {
            droppedFrames += 1
            if droppedFrames == 1 || droppedFrames % 100 == 0 {
                Log.client.debug("H.264: \(self.droppedFrames) slices dropped waiting for parameter sets")
            }
            return nil
        }

        if awaitingKeyframe {
            guard isKeyframe else {
                droppedFrames += 1
                return nil
            }
            awaitingKeyframe = false
        }

        guard let sample = makeSampleBuffer(slices, format: formatDescription, timestamp: timestamp) else {
            noteFailure("could not build a sample buffer from \(slices.count) slices")
            return nil
        }

        let output = DecodeOutput()
        let status = VTDecompressionSessionDecodeFrame(
            session.session,
            sampleBuffer: sample,
            flags: [],
            infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            output.status = status
            guard status == noErr, let imageBuffer else { return }
            var created: CGImage?
            VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &created)
            output.image = created
        }

        let failure = status != noErr ? status : output.status
        guard failure == noErr else {
            handleDecodeFailure(failure)
            return nil
        }
        guard let image = output.image else {
            // Accepted but not emitted: the decoder held or dropped it. Not a
            // fault, and not something to resync over.
            return nil
        }

        decodedFrames += 1
        return DecodedFrame(image: image, timestamp: timestamp, byteCount: data.count)
    }

    // MARK: Configuration

    private func configure(sps: Data, pps: Data) {
        guard let description = Self.makeFormatDescription(sps: sps, pps: pps) else {
            noteFailure("SPS/PPS of \(sps.count)/\(pps.count) bytes were rejected")
            return
        }

        self.sps = sps
        self.pps = pps
        formatDescription = description

        // A session that can take the new description is kept: on real
        // hardware creating one is the slow part, and a camera that re-sends
        // identical parameter sets with every keyframe must not pay it each
        // second.
        if let session,
           VTDecompressionSessionCanAcceptFormatDescription(session.session, formatDescription: description) {
            return
        }
        session = nil

        // BGRA out, so the CGImage is a wrap of the decoder's output rather
        // than a second conversion done in software afterwards.
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                  formatDescription: description,
                                                  decoderSpecification: nil,
                                                  imageBufferAttributes: attributes as CFDictionary,
                                                  outputCallback: nil,
                                                  decompressionSessionOut: &created)
        guard status == noErr, let created else {
            noteFailure("VTDecompressionSessionCreate failed (\(status))")
            return
        }
        session = SessionHandle(created)
        awaitingKeyframe = true

        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        Log.client.info("H.264 decoder ready for \(dimensions.width)×\(dimensions.height)")
    }

    private static func makeFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        guard !sps.isEmpty, !pps.isEmpty else { return nil }
        var description: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description)
            }
        }
        return status == noErr ? description : nil
    }

    // MARK: Sample buffers

    /// Packs slices as AVCC — each prefixed with its four-byte length — which is
    /// the layout the format description above declares.
    private func makeSampleBuffer(_ slices: [H264NALUnit],
                                  format: CMVideoFormatDescription,
                                  timestamp: Date) -> CMSampleBuffer? {
        var avcc = Data(capacity: slices.reduce(0) { $0 + $1.payload.count + 4 })
        for slice in slices {
            var length = UInt32(slice.payload.count).bigEndian
            avcc.append(Data(bytes: &length, count: 4))
            avcc.append(slice.payload)
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                        memoryBlock: nil,
                                                        blockLength: avcc.count,
                                                        blockAllocator: kCFAllocatorDefault,
                                                        customBlockSource: nil,
                                                        offsetToData: 0,
                                                        dataLength: avcc.count,
                                                        flags: 0,
                                                        blockBufferOut: &blockBuffer)
        guard status == noErr, let blockBuffer else { return nil }

        status = avcc.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!,
                                          blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0,
                                          dataLength: avcc.count)
        }
        guard status == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: timestamp.timeIntervalSince1970,
                                          preferredTimescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sampleSize = avcc.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                           dataBuffer: blockBuffer,
                                           formatDescription: format,
                                           sampleCount: 1,
                                           sampleTimingEntryCount: 1,
                                           sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1,
                                           sampleSizeArray: &sampleSize,
                                           sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }

    // MARK: Failures

    private func handleDecodeFailure(_ status: OSStatus) {
        if status == kVTInvalidSessionErr {
            // The system revoked the hardware session — the app was
            // backgrounded, typically. Not the stream's fault; rebuild on the
            // next frame and start again from a keyframe.
            Log.client.info("H.264 decompression session invalidated; will rebuild")
            session = nil
        } else {
            noteFailure("VideoToolbox refused a frame (\(status))")
        }
        // Whatever went wrong, the reference pictures are now suspect.
        awaitingKeyframe = true
    }

    private func noteFailure(_ message: String) {
        failures += 1
        if failures <= 3 || failures % 100 == 0 {
            Log.client.error("H.264: \(message, privacy: .public) (\(self.failures) failures so far)")
        }
    }
}
