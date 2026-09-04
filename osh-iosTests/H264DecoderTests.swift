import Foundation
import Testing
@testable import osh_ios

// MARK: - H264DecoderTests
//
// Against the video-h264 fixture: six consecutive WebSocket messages from a
// node camera, the first an IDR with its SPS and PPS prepended, the other five
// P-frames that depend on it. That order is what lets these tests say both
// "a keyframe decodes" and "a P-frame after it decodes", and the reverse — a
// P-frame with nothing to refer to is dropped.

struct H264DecoderTests {

    // MARK: Helpers

    /// The fixture's frames as (block, phenomenonTime), in stream order.
    private static func fixtureBlocks() throws -> [(Data, Date)] {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.videoH264, "schema-binary.json"))
        let decoder = try DatastreamDecoder(datastreamId: "video", schema: schema)
        #expect(decoder.blockCompression == "H264")

        var blocks: [(Data, Date)] = []
        for message in try FixtureLoader.binaryMessages(.videoH264) {
            for observation in try decoder.decode(binary: message) {
                guard case .block(let data, _)? = observation.values.values.first(where: {
                    if case .block = $0 { return true } else { return false }
                }) else { continue }
                blocks.append((data, observation.phenomenonTime))
            }
        }
        return blocks
    }

    private static func annexB(_ units: [[UInt8]], longStartCode: Bool = true) -> Data {
        var data = Data()
        for unit in units {
            data.append(contentsOf: longStartCode ? [0, 0, 0, 1] : [0, 0, 1])
            data.append(contentsOf: unit)
        }
        return data
    }

    // MARK: NAL splitting

    @Test("The fixture's keyframe carries SPS, PPS and an IDR; the rest are P slices")
    func fixtureNALTypes() throws {
        let blocks = try Self.fixtureBlocks()
        #expect(blocks.count == 6)

        let first = H264AccessUnit.nalUnits(in: blocks[0].0).map(\.type)
        // The camera sends its parameter sets twice per keyframe. Both copies
        // must survive the split — the decoder keeps the last.
        #expect(first == [7, 8, 7, 8, 5])

        for (data, _) in blocks.dropFirst() {
            #expect(H264AccessUnit.nalUnits(in: data).map(\.type) == [1])
        }
    }

    @Test("Short start codes and trailing zeros are framing, not payload")
    func annexBFraming() {
        let sps: [UInt8] = [0x67, 0x42, 0x00, 0x1F]
        let pps: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]
        let idr: [UInt8] = [0x65, 0x88, 0x84, 0x01]

        // 00 00 01 start codes, trailing_zero_8bits after the PPS and again
        // after the last unit.
        var data = Self.annexB([sps], longStartCode: false)
        data.append(contentsOf: [0, 0, 1])
        data.append(contentsOf: pps)
        data.append(contentsOf: [0, 0])
        data.append(contentsOf: [0, 0, 0, 1])
        data.append(contentsOf: idr)
        data.append(contentsOf: [0, 0])

        let units = H264AccessUnit.nalUnits(in: data)
        #expect(units.map(\.type) == [7, 8, 5])
        #expect(units[0].payload == Data(sps))
        #expect(units[1].payload == Data(pps))
        // A NAL unit never ends in 0x00 — its trailing bits end in a stop bit
        // — so zeros after the last one are framing too.
        #expect(units[2].payload == Data(idr))
    }

    @Test("A block with no start code is accepted as AVCC only when its lengths tile it")
    func avccFallback() {
        var avcc = Data()
        for unit in [[0x67, 0x42, 0x00], [0x68, 0xCE], [0x65, 0x88, 0x84, 0x01]] as [[UInt8]] {
            var length = UInt32(unit.count).bigEndian
            avcc.append(Data(bytes: &length, count: 4))
            avcc.append(contentsOf: unit)
        }
        #expect(H264AccessUnit.nalUnits(in: avcc).map(\.type) == [7, 8, 5])

        // One byte short, and it is neither layout.
        #expect(H264AccessUnit.nalUnits(in: avcc.dropLast()).isEmpty)
        #expect(H264AccessUnit.nalUnits(in: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])).isEmpty)
        #expect(H264AccessUnit.nalUnits(in: Data()).isEmpty)
    }

    // MARK: Decoding

    @Test("A keyframe and the P-frames after it all decode to pictures")
    func decodesFixtureGOP() async throws {
        let blocks = try Self.fixtureBlocks()
        let decoder = H264Decoder()

        var frames: [DecodedFrame] = []
        for (data, timestamp) in blocks {
            if let frame = await decoder.decode(data, timestamp: timestamp) {
                #expect(frame.byteCount == data.count)
                #expect(frame.timestamp == timestamp)
                frames.append(frame)
            }
        }

        #expect(frames.count == blocks.count, "every frame of a GOP that starts at its IDR decodes")
        let first = try #require(frames.first)
        #expect(first.width >= 64 && first.width <= 8192)
        #expect(first.height >= 64 && first.height <= 8192)
        #expect(frames.allSatisfy { $0.width == first.width && $0.height == first.height })
        #expect(await decoder.decodedFrames == blocks.count)
        #expect(await decoder.droppedFrames == 0)
    }

    @Test("P-frames before the first keyframe are dropped, not decoded against nothing")
    func waitsForKeyframe() async throws {
        let blocks = try Self.fixtureBlocks()
        let decoder = H264Decoder()

        // The GOP fed tail-first: five slices with no parameter sets and no
        // reference picture, then the IDR.
        for (data, timestamp) in blocks.dropFirst() {
            #expect(await decoder.decode(data, timestamp: timestamp) == nil)
        }
        #expect(await decoder.droppedFrames == 5)
        #expect(await decoder.decodedFrames == 0)

        let keyframe = try #require(await decoder.decode(blocks[0].0, timestamp: blocks[0].1))
        #expect(keyframe.width > 0)

        // Once the reference exists, the same P-frames decode.
        let next = try #require(await decoder.decode(blocks[1].0, timestamp: blocks[1].1))
        #expect(next.width == keyframe.width)
    }

    @Test("Garbage is reported as nothing to draw, never thrown")
    func rejectsGarbage() async {
        let decoder = H264Decoder()
        #expect(await decoder.decode(Data(), timestamp: Date()) == nil)
        #expect(await decoder.decode(Data([0, 1, 2, 3, 4, 5]), timestamp: Date()) == nil)
        // A well-formed Annex B stream of only parameter sets: kept, not drawn.
        let parameterSets = Self.annexB([[0x67, 0x42, 0x00, 0x1F, 0x95, 0xA8, 0x14, 0x01, 0x6E, 0x40],
                                         [0x68, 0xCE, 0x3C, 0x80]])
        #expect(await decoder.decode(parameterSets, timestamp: Date()) == nil)
        #expect(await decoder.decodedFrames == 0)
    }

    // MARK: Codec recognition

    @Test("VideoCodec sorts the node's spellings into decoders")
    func codecRecognition() {
        #expect(VideoCodec(compression: "JPEG") == .jpeg)
        #expect(VideoCodec(compression: "MJPEG") == .jpeg)
        #expect(VideoCodec(compression: "jpg") == .jpeg)
        #expect(VideoCodec(compression: "H264") == .h264)
        #expect(VideoCodec(compression: "h.264") == .h264)
        #expect(VideoCodec(compression: "avc1") == .h264)
        #expect(VideoCodec(compression: "H265") == .unsupported("H265"))
        #expect(VideoCodec(compression: nil) == .unsupported(nil))

        #expect(VideoCodec(compression: "H264").isDecodable)
        #expect(VideoCodec(compression: "JPEG").isDecodable)
        #expect(!VideoCodec(compression: "HEVC").isDecodable)
        #expect(!VideoCodec(compression: nil).isDecodable)
    }
}
