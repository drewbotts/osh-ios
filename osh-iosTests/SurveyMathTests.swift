import Testing
import Foundation
@testable import osh_ios

// MARK: - SurveyMathTests

@Suite("Survey math")
struct SurveyMathTests {

    // MARK: Circular mean

    @Test("Headings straddling north average to north, not south")
    func straddlesNorth() throws {
        let mean = try #require(SurveyMath.circularMean(degrees: [359, 1, 358, 2, 0]))
        #expect(abs(SurveyMath.signedDifference(mean, minus: 0)) < 1e-9)
    }

    @Test("Headings straddling north with unequal weights lean the weighted way")
    func straddlesNorthWeighted() throws {
        let mean = try #require(SurveyMath.circularMean(degrees: [350, 10], weights: [3, 1]))
        #expect(mean > 350 && mean < 360)
    }

    @Test("A plain cluster averages arithmetically")
    func plainCluster() throws {
        let mean = try #require(SurveyMath.circularMean(degrees: [88, 90, 92]))
        #expect(abs(mean - 90) < 1e-9)
    }

    @Test("Opposite headings have no mean")
    func oppositeHeadings() {
        #expect(SurveyMath.circularMean(degrees: [0, 180]) == nil)
        #expect(SurveyMath.circularMean(degrees: []) == nil)
    }

    @Test("Spread is zero for agreement and grows with scatter")
    func spread() throws {
        #expect(try #require(SurveyMath.circularSpread(degrees: [45, 45, 45])) < 1e-6)
        let tight = try #require(SurveyMath.circularSpread(degrees: [358, 0, 2]))
        let loose = try #require(SurveyMath.circularSpread(degrees: [340, 0, 20]))
        #expect(tight > 1 && tight < 3)
        #expect(loose > tight)
    }

    @Test("normalizedDegrees and signedDifference behave at the wrap")
    func wrapHelpers() {
        #expect(SurveyMath.normalizedDegrees(-90) == 270)
        #expect(SurveyMath.normalizedDegrees(360) == 0)
        #expect(SurveyMath.normalizedDegrees(725.5) == 5.5)
        #expect(SurveyMath.signedDifference(10, minus: 350) == 20)
        #expect(SurveyMath.signedDifference(350, minus: 10) == -20)
        #expect(SurveyMath.signedDifference(180, minus: 0) == 180)
    }

    // MARK: Weighted position

    private func sample(_ lat: Double, _ lon: Double, hae: Double = 200, msl: Double = 230,
                        accuracy: Double, vertical: Double = -1, t: TimeInterval = 0) -> LocationSample {
        LocationSample(latitude: lat, longitude: lon, ellipsoidalAltitude: hae, altitudeMSL: msl,
                       horizontalAccuracy: accuracy, verticalAccuracy: vertical,
                       timestamp: Date(timeIntervalSince1970: t))
    }

    @Test("A 4 m fix outweighs a 16 m fix sixteen to one")
    func accuracyWeighting() throws {
        let estimate = try #require(SurveyMath.averagePosition([
            sample(34.0, -86.0, accuracy: 4),
            sample(34.0017, -86.0, accuracy: 16)   // 17 units north
        ]))
        // Weighted mean: (16·0 + 1·17)/17 = 1 unit.
        #expect(abs(estimate.latitude - 34.0001) < 1e-9)
        #expect(estimate.sampleCount == 2)
        // The quoted accuracy is the weighted mean of the inputs: (16·4 + 1·16)/17.
        #expect(abs(estimate.horizontalAccuracy - (16 * 4 + 16) / 17) < 1e-9)
    }

    @Test("Fixes without an accuracy figure are excluded")
    func excludesInvalidAccuracy() throws {
        let estimate = try #require(SurveyMath.averagePosition([
            sample(34.0, -86.0, accuracy: 5),
            sample(35.0, -87.0, accuracy: -1)
        ]))
        #expect(estimate.latitude == 34.0)
        #expect(estimate.sampleCount == 1)
        #expect(SurveyMath.averagePosition([sample(34, -86, accuracy: 0)]) == nil)
    }

    @Test("Both altitudes are carried and averaged")
    func altitudes() throws {
        let estimate = try #require(SurveyMath.averagePosition([
            sample(34, -86, hae: 200, msl: 230, accuracy: 5, vertical: 3),
            sample(34, -86, hae: 210, msl: 240, accuracy: 5, vertical: 3)
        ]))
        #expect(abs(estimate.heightAboveEllipsoid - 205) < 1e-9)
        #expect(abs(estimate.altitudeMSL - 235) < 1e-9)
        #expect(estimate.verticalAccuracy == 3)
    }

    @Test("Vertical accuracy is nil unless every fix has one")
    func verticalAccuracyOptional() throws {
        let estimate = try #require(SurveyMath.averagePosition([
            sample(34, -86, accuracy: 5, vertical: 3),
            sample(34, -86, accuracy: 5, vertical: -1)
        ]))
        #expect(estimate.verticalAccuracy == nil)
    }

    @Test("Longitude averages across the antimeridian")
    func antimeridian() throws {
        let estimate = try #require(SurveyMath.averagePosition([
            sample(0, 179.9, accuracy: 5),
            sample(0, -179.9, accuracy: 5)
        ]))
        #expect(abs(abs(estimate.longitude) - 180) < 1e-6)
    }

    @Test("Accuracy weights floor at one metre")
    func weightFloor() {
        let weights = SurveyMath.accuracyWeights([0.1, 1, 2, -3])
        #expect(weights[0] == 1)
        #expect(weights[1] == 1)
        #expect(weights[2] == 0.25)
        #expect(weights[3] == 0)
    }

    // MARK: Heading and attitude estimates

    @Test("Heading estimate averages around the wrap and reports its spread")
    func headingEstimate() throws {
        let samples = [359.0, 0.5, 1.0, 358.5].enumerated().map { index, heading in
            OrientationSample(heading: heading, pitch: 0, roll: 0,
                              timestamp: Date(timeIntervalSince1970: Double(index)))
        }
        let estimate = try #require(SurveyMath.averageHeading(samples))
        #expect(abs(SurveyMath.signedDifference(estimate.heading, minus: 359.75)) < 1e-9)
        #expect(estimate.spread > 0 && estimate.spread < 2)
        #expect(estimate.sampleCount == 4)
    }

    @Test("Attitude estimate averages pitch plainly and roll around the wrap")
    func attitudeEstimate() throws {
        let samples = [(10.0, 179.0), (20.0, -179.0)].enumerated().map { index, pair in
            OrientationSample(heading: 0, pitch: pair.0, roll: pair.1,
                              timestamp: Date(timeIntervalSince1970: Double(index)))
        }
        let estimate = try #require(SurveyMath.averageAttitude(samples))
        #expect(abs(estimate.pitch - 15) < 1e-9)
        #expect(abs(abs(estimate.roll) - 180) < 1e-6)
    }
}
