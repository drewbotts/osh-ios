import Foundation

// MARK: - Survey samples and estimates
//
// The arithmetic of a survey-in, kept apart from CoreLocation and CoreMotion so
// it can be tested with numbers rather than with a phone.
//
// Two things here are easy to get wrong and are the reason this file exists.
//
// A heading cannot be averaged like a distance. Five samples of 359° and five of
// 1° describe a phone pointing north; their arithmetic mean is 180°, due south.
// Headings are averaged as unit vectors and the angle of the resultant is the
// mean — the circular mean — and the length of that resultant says how tightly
// the samples agreed.
//
// A position fix comes with its own uncertainty, and a survey standing still
// for five seconds collects fixes of very different quality as the receiver
// settles. Weighting each fix by 1/σ² lets a 4 m fix count sixteen times as
// much as a 16 m one, which is how a least-squares estimate would treat them.

/// One location fix, reduced to the figures a survey needs.
struct LocationSample: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    /// Metres above the WGS 84 ellipsoid (`CLLocation.ellipsoidalAltitude`).
    var ellipsoidalAltitude: Double
    /// Metres above mean sea level (`CLLocation.altitude`), for reference only.
    var altitudeMSL: Double
    /// Metres; a fix with no accuracy figure (CoreLocation reports a negative
    /// number) is not a survey sample and should not be constructed.
    var horizontalAccuracy: Double
    /// Metres, or a non-positive value when unknown.
    var verticalAccuracy: Double
    var timestamp: Date
}

/// One attitude sample.
struct OrientationSample: Equatable, Sendable {
    /// Degrees clockwise from true north, [0, 360).
    var heading: Double
    /// Degrees, positive nose-up.
    var pitch: Double
    /// Degrees, positive right-side-down.
    var roll: Double
    var timestamp: Date
}

/// The averaged position.
struct PositionEstimate: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var heightAboveEllipsoid: Double
    var altitudeMSL: Double
    /// The accuracy-weighted mean of the contributing fixes' own horizontal
    /// accuracies, in metres.
    ///
    /// Not √(1/Σwᵢ): that formula assumes independent errors, and consecutive
    /// fixes from one receiver standing still are anything but. Quoting the
    /// typical accuracy of the fixes that went in is honest; quoting a figure
    /// that shrinks with every second of standing still would not be.
    var horizontalAccuracy: Double
    /// As `horizontalAccuracy`, for height; nil when no fix carried one.
    var verticalAccuracy: Double?
    var sampleCount: Int
}

/// The averaged heading.
struct HeadingEstimate: Equatable, Sendable {
    /// Degrees clockwise from true north, [0, 360).
    var heading: Double
    /// Circular standard deviation in degrees: how far the samples strayed from
    /// the mean. Small when the phone was held still, large when it wobbled or
    /// the magnetometer was being pulled about.
    var spread: Double
    var sampleCount: Int
}

/// The averaged pitch and roll.
struct AttitudeEstimate: Equatable, Sendable {
    var pitch: Double
    var roll: Double
    var sampleCount: Int
}

// MARK: - SurveyMath

enum SurveyMath {

    // MARK: Angles

    /// `degrees` brought into [0, 360).
    static func normalizedDegrees(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        // -0.0 and a remainder that rounds back up to 360 both belong at 0.
        return value >= 360 || value == 0 ? 0 : value
    }

    /// `a − b` taken the short way round, in (−180, 180].
    static func signedDifference(_ a: Double, minus b: Double) -> Double {
        var difference = (a - b).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 }
        if difference <= -180 { difference += 360 }
        return difference
    }

    /// The circular mean of headings in degrees, or nil when it is undefined:
    /// no samples, or samples so evenly spread (two opposite headings) that
    /// the resultant vanishes.
    ///
    /// - Parameter weights: per-sample weights; equal when omitted.
    static func circularMean(degrees: [Double], weights: [Double]? = nil) -> Double? {
        resultant(degrees: degrees, weights: weights).map { normalizedDegrees($0.angle) }
    }

    /// Circular standard deviation, in degrees, of `degrees` about their mean:
    /// √(−2 ln R̄) where R̄ is the mean resultant length. 0 for perfect
    /// agreement, rising without bound as the samples scatter.
    static func circularSpread(degrees: [Double], weights: [Double]? = nil) -> Double? {
        guard let resultant = resultant(degrees: degrees, weights: weights) else { return nil }
        let length = min(max(resultant.length, 1e-12), 1)
        return sqrt(-2 * log(length)) * 180 / .pi
    }

    /// Mean resultant vector of unit vectors at `degrees`: its angle (degrees,
    /// maths convention converted back to compass) and its length in [0, 1].
    private static func resultant(degrees: [Double],
                                  weights: [Double]?) -> (angle: Double, length: Double)? {
        guard !degrees.isEmpty else { return nil }
        let weights = weights ?? Array(repeating: 1, count: degrees.count)
        guard weights.count == degrees.count else { return nil }

        var sumSin = 0.0, sumCos = 0.0, sumWeights = 0.0
        for (heading, weight) in zip(degrees, weights) where weight > 0 && heading.isFinite {
            let radians = heading * .pi / 180
            sumSin += weight * sin(radians)
            sumCos += weight * cos(radians)
            sumWeights += weight
        }
        guard sumWeights > 0 else { return nil }

        let length = hypot(sumSin, sumCos) / sumWeights
        guard length > 1e-9 else { return nil }
        return (atan2(sumSin, sumCos) * 180 / .pi, length)
    }

    // MARK: Weights

    /// 1/σ² for each accuracy, with σ floored at `floor` metres so a receiver
    /// claiming centimetre accuracy for one sample cannot swamp the rest.
    /// Non-positive accuracies weigh nothing.
    static func accuracyWeights(_ accuracies: [Double], floor: Double = 1) -> [Double] {
        accuracies.map { accuracy in
            guard accuracy > 0, accuracy.isFinite else { return 0 }
            let sigma = max(accuracy, floor)
            return 1 / (sigma * sigma)
        }
    }

    /// Σwᵢxᵢ / Σwᵢ, or nil when nothing has weight.
    static func weightedMean(_ values: [Double], weights: [Double]) -> Double? {
        guard values.count == weights.count else { return nil }
        var sum = 0.0, sumWeights = 0.0
        for (value, weight) in zip(values, weights) where weight > 0 && value.isFinite {
            sum += weight * value
            sumWeights += weight
        }
        guard sumWeights > 0 else { return nil }
        return sum / sumWeights
    }

    // MARK: Estimates

    /// The accuracy-weighted mean position of `samples`.
    ///
    /// Latitude is a plain weighted mean; longitude goes through the circular
    /// mean so a survey straddling the antimeridian does not land on the far
    /// side of the planet. Heights use vertical accuracy for weights when
    /// every fix has one, horizontal accuracy otherwise — a fix that is good
    /// on the ground is usually good in height, and mixing the two schemes
    /// would weight some fixes by a different quantity from the others.
    static func averagePosition(_ samples: [LocationSample]) -> PositionEstimate? {
        let usable = samples.filter { $0.horizontalAccuracy > 0 }
        guard !usable.isEmpty else { return nil }

        let horizontalWeights = accuracyWeights(usable.map(\.horizontalAccuracy))
        let verticalAccuracies = usable.map(\.verticalAccuracy)
        let allHaveVertical = verticalAccuracies.allSatisfy { $0 > 0 }
        let verticalWeights = allHaveVertical ? accuracyWeights(verticalAccuracies) : horizontalWeights

        guard let latitude = weightedMean(usable.map(\.latitude), weights: horizontalWeights),
              let longitudeCircular = circularMean(degrees: usable.map(\.longitude),
                                                   weights: horizontalWeights),
              let hae = weightedMean(usable.map(\.ellipsoidalAltitude), weights: verticalWeights),
              let msl = weightedMean(usable.map(\.altitudeMSL), weights: verticalWeights),
              let horizontalAccuracy = weightedMean(usable.map(\.horizontalAccuracy),
                                                    weights: horizontalWeights)
        else { return nil }

        let longitude = longitudeCircular > 180 ? longitudeCircular - 360 : longitudeCircular
        let verticalAccuracy = allHaveVertical
            ? weightedMean(verticalAccuracies, weights: verticalWeights)
            : nil

        return PositionEstimate(latitude: latitude,
                                longitude: longitude,
                                heightAboveEllipsoid: hae,
                                altitudeMSL: msl,
                                horizontalAccuracy: horizontalAccuracy,
                                verticalAccuracy: verticalAccuracy,
                                sampleCount: usable.count)
    }

    /// The circular mean heading of `samples`, with its spread.
    static func averageHeading(_ samples: [OrientationSample]) -> HeadingEstimate? {
        let headings = samples.map(\.heading)
        guard let heading = circularMean(degrees: headings),
              let spread = circularSpread(degrees: headings) else { return nil }
        return HeadingEstimate(heading: heading, spread: spread, sampleCount: samples.count)
    }

    /// Mean pitch and roll. Pitch lives in [−90, 90] and averages plainly; roll
    /// wraps at ±180 and takes the circular route.
    static func averageAttitude(_ samples: [OrientationSample]) -> AttitudeEstimate? {
        guard !samples.isEmpty else { return nil }
        let weights = Array(repeating: 1.0, count: samples.count)
        guard let pitch = weightedMean(samples.map(\.pitch), weights: weights),
              let rollCircular = circularMean(degrees: samples.map(\.roll)) else { return nil }
        let roll = rollCircular > 180 ? rollCircular - 360 : rollCircular
        return AttitudeEstimate(pitch: pitch, roll: roll, sampleCount: samples.count)
    }
}
