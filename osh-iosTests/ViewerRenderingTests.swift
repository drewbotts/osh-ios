import Testing
import Foundation
import CoreLocation
@testable import osh_ios

// MARK: - ViewerRenderingTests
//
// The parts of the viewer that produce pixels or coordinates rather than
// classifications: the waterfall buffer, the MJPEG decoder, and the geodesy a
// line of bearing depends on.
//
// All three are tested against captured bytes wherever the node produced any,
// because all three fail quietly. A waterfall drawn from the wrong scale is
// still a picture; a bearing line computed in screen space still points
// somewhere.

@Suite("Viewer rendering")
struct ViewerRenderingTests {

    // MARK: Waterfall

    /// The spectrum fixture's observations, oldest first.
    private static func spectra() throws -> [ParsedObservation] {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.spectrumArray, "schema-binary.json"))
        let decoder = try DatastreamDecoder(datastreamId: "spectrum", schema: schema)
        return try FixtureLoader.binaryMessages(.spectrumArray)
            .flatMap { try decoder.decode(binary: $0) }
    }

    @Test("Spectrum observations expose their array as an ordered series")
    func seriesReaderFindsTheArray() throws {
        let observations = try Self.spectra()
        let first = try #require(observations.first)
        let series = SeriesReader.values(of: first, at: FieldPath("/amplitude"))
        #expect(series.count > 8, "expected a real spectrum, got \(series.count) bins")
        #expect(series.allSatisfy { $0.isFinite })

        let axis = SeriesReader.values(of: first, at: FieldPath("/frequency_axis"))
        #expect(axis.count == series.count)
        // A frequency axis is monotonic; if the index parsing were wrong the
        // values would come back shuffled by string ordering ("10" before "2").
        #expect(zip(axis, axis.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("The buffer takes one row per observation and resamples to its width")
    func waterfallRowsAndWidth() throws {
        let observations = try Self.spectra()
        var buffer = WaterfallBuffer(rowCount: 8, columnCount: 64)

        for observation in observations {
            buffer.append(SeriesReader.values(of: observation, at: FieldPath("/amplitude")))
        }
        #expect(buffer.filledRows == observations.count)

        let image = try #require(buffer.makeImage())
        #expect(image.width == 64)
        #expect(image.height == 8)
        #expect(buffer.minimum < buffer.maximum)
    }

    @Test("More rows than the ring holds keeps the ring's size")
    func waterfallRingIsBounded() {
        var buffer = WaterfallBuffer(rowCount: 4, columnCount: 16)
        for index in 0..<50 {
            buffer.append((0..<32).map { Double($0 + index) * -1 })
        }
        #expect(buffer.filledRows == 4)
        #expect(buffer.makeImage()?.height == 4)
    }

    /// A bin the receiver could not measure must map to the bottom of the
    /// colormap rather than to whatever a comparison against NaN returns.
    @Test("NaN and infinities map to the bottom colour and do not crash")
    func waterfallHandlesNonFiniteValues() {
        var buffer = WaterfallBuffer(rowCount: 3, columnCount: 8)
        buffer.append([-90, -80, .nan, -70, .infinity, -60, -.infinity, -50])
        buffer.append([Double.nan, .nan, .nan, .nan, .nan, .nan, .nan, .nan])
        buffer.append([-95, -85, -75, -65, -55, -45, -35, -25])

        #expect(buffer.filledRows == 3)
        #expect(buffer.minimum.isFinite)
        #expect(buffer.maximum.isFinite)
        #expect(buffer.makeImage() != nil)
    }

    @Test("An all-positive series is read as linear power and converted to dB")
    func waterfallConvertsLinearPower() {
        let converted = WaterfallBuffer.asDecibels([1, 10, 100])
        #expect(abs(converted[0] - 0) < 1e-9)
        #expect(abs(converted[1] - 10) < 1e-9)
        #expect(abs(converted[2] - 20) < 1e-9)

        // Anything negative can only already be logarithmic — power is not.
        let untouched = WaterfallBuffer.asDecibels([-90, -80, 5])
        #expect(untouched == [-90, -80, 5])
    }

    @Test("The colormap covers its whole range and is bounded at both ends")
    func viridisTable() {
        #expect(Viridis.table.count == 256)
        let low = Viridis.colour(at: -5)
        let high = Viridis.colour(at: 5)
        #expect(low.red == Viridis.table[0].red)
        #expect(high.red == Viridis.table[255].red)
    }

    // MARK: MJPEG

    @Test("MJPEG frames decode to plausible images")
    func mjpegDecodesFixtureFrames() async throws {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.videoMJPEG, "schema-binary.json"))
        let decoder = try DatastreamDecoder(datastreamId: "video1", schema: schema)
        #expect(decoder.blockCompression == "JPEG")

        var decoded = 0
        for message in try FixtureLoader.binaryMessages(.videoMJPEG) {
            for observation in try decoder.decode(binary: message) {
                guard case .block(let data, let compression)? =
                        observation.values.values.first(where: {
                            if case .block = $0 { return true } else { return false }
                        }) else { continue }
                #expect(MJPEGDecoder.canDecode(compression: compression ?? "JPEG"))

                let frame = try #require(
                    await MJPEGDecoder.shared.decode(data, timestamp: observation.phenomenonTime))
                #expect(frame.width >= 64 && frame.width <= 8192)
                #expect(frame.height >= 64 && frame.height <= 8192)
                #expect(frame.byteCount == data.count)
                decoded += 1
            }
        }
        #expect(decoded >= 1, "no MJPEG frames decoded from the fixture")
    }

    @Test("A truncated frame is dropped rather than thrown")
    func mjpegDropsTruncatedFrames() async throws {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.videoMJPEG, "schema-binary.json"))
        let decoder = try DatastreamDecoder(datastreamId: "video1", schema: schema)

        let messages = try FixtureLoader.binaryMessages(.videoMJPEG)
        let message = try #require(messages.first)
        let decodedObservations = try decoder.decode(binary: message)
        let observation = try #require(decodedObservations.first)
        guard case .block(let data, _)? = observation.values.values.first(where: {
            if case .block = $0 { return true } else { return false }
        }) else {
            Issue.record("fixture carried no block")
            return
        }

        // Half a JPEG: the marker is there, the scan is not.
        let truncated = data.prefix(data.count / 2)
        #expect(await MJPEGDecoder.shared.decode(Data(truncated), timestamp: Date()) == nil)
        #expect(await MJPEGDecoder.shared.decode(Data(), timestamp: Date()) == nil)
        #expect(await MJPEGDecoder.shared.decode(Data([0, 1, 2, 3]), timestamp: Date()) == nil)
    }

    @Test("Codec recognition tells JPEG from H.264")
    func codecRecognition() {
        #expect(MJPEGDecoder.canDecode(compression: "JPEG"))
        #expect(MJPEGDecoder.canDecode(compression: "MJPEG"))
        #expect(!MJPEGDecoder.canDecode(compression: "H264"))
        #expect(!MJPEGDecoder.canDecode(compression: nil))
        #expect(MJPEGDecoder.isH264(compression: "H264"))
        #expect(MJPEGDecoder.isH264(compression: "avc1"))
        #expect(!MJPEGDecoder.isH264(compression: "JPEG"))
    }

    // MARK: Bearing geodesy

    @Test("Due north and due east land where they should")
    func bearingCardinalDirections() {
        let origin = CLLocationCoordinate2D(latitude: 34.725, longitude: -86.583)

        let north = BearingGeometry.destination(from: origin,
                                                bearingDegrees: 0,
                                                distanceMeters: BearingStyle.lineLength)
        #expect(north.latitude > origin.latitude)
        #expect(abs(north.longitude - origin.longitude) < 1e-6)

        let east = BearingGeometry.destination(from: origin,
                                               bearingDegrees: 90,
                                               distanceMeters: BearingStyle.lineLength)
        #expect(east.longitude > origin.longitude)
        #expect(abs(east.latitude - origin.latitude) < 1e-4)
    }

    /// The whole reason the endpoint is computed on the sphere: a degree of
    /// longitude is half as long at 60° north as it is at the equator, so the
    /// same eastward distance must move the longitude twice as far.
    @Test("Longitude change scales with latitude, which is why this is not screen space")
    func bearingAccountsForLatitude() {
        let equator = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let far = CLLocationCoordinate2D(latitude: 60, longitude: 0)

        let atEquator = BearingGeometry.destination(from: equator, bearingDegrees: 90,
                                                    distanceMeters: 100_000).longitude
        let atSixty = BearingGeometry.destination(from: far, bearingDegrees: 90,
                                                  distanceMeters: 100_000).longitude
        #expect(atSixty > atEquator * 1.9)
        #expect(atSixty < atEquator * 2.1)
    }

    @Test("Distance travelled matches the distance asked for")
    func bearingDistanceIsAccurate() {
        let origin = CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3)
        for bearing in stride(from: 0.0, to: 360.0, by: 45) {
            let end = BearingGeometry.destination(from: origin,
                                                  bearingDegrees: bearing,
                                                  distanceMeters: 2000)
            let measured = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            #expect(abs(measured - 2000) < 10, "bearing \(bearing) travelled \(measured) m")
        }
    }

    @Test("A line older than the stale window fades but is still drawn")
    func bearingFadesRatherThanDisappearing() {
        let now = Date()
        let fresh = BearingStyle.opacity(at: now, now: now)
        let old = BearingStyle.opacity(at: now.addingTimeInterval(-3600), now: now)
        #expect(fresh == BearingStyle.freshOpacity)
        #expect(old == BearingStyle.staleOpacity)
        #expect(old > 0, "a stale LOB must never become invisible")
    }

    @Test("The antimeridian does not send a line the long way round")
    func bearingWrapsLongitude() {
        let origin = CLLocationCoordinate2D(latitude: 0, longitude: 179.99)
        let end = BearingGeometry.destination(from: origin, bearingDegrees: 90,
                                              distanceMeters: 5000)
        #expect(end.longitude <= 180)
        #expect(end.longitude >= -180)
        #expect(end.longitude < 0, "crossing 180° must wrap to a negative longitude")
    }
}
