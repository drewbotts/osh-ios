import Foundation
import CoreGraphics

// MARK: - WaterfallBuffer
//
// The pixels behind an SDR waterfall, and nothing else — no SwiftUI, no view
// sizing, no Charts. That separation is what makes 10 Hz × 4096 bins possible:
// the alternative, a view per cell or a Chart per frame, allocates hundreds of
// thousands of objects a second and janks long before the data does.
//
// The buffer is a fixed BGRA bitmap, newest row at the top. A new observation
// moves the whole image down one row with a single memmove and writes one row
// of pixels; nothing else is touched, and the CGImage is rebuilt from the same
// backing store.
//
// Amplitude to colour goes through a rolling minimum and maximum over the rows
// still in the buffer, so a signal that appears twenty dB above the noise floor
// is visible without anyone choosing a scale first.

struct WaterfallBuffer {

    // MARK: Geometry

    /// Rows kept — how far back the waterfall scrolls.
    let rowCount: Int
    /// Columns — the array is resampled to this width once, at write time, so
    /// the per-frame cost does not depend on how many bins the node sends.
    let columnCount: Int

    private static let bytesPerPixel = 4

    private var pixels: [UInt8]
    /// How many rows have been written, capped at `rowCount`.
    private(set) var filledRows = 0

    /// The dB range currently mapped onto the colormap, for the axis labels.
    private(set) var minimum: Double = 0
    private(set) var maximum: Double = 1

    /// Row minima and maxima, kept alongside the pixels so the rolling range
    /// can be recomputed without decoding the image back into numbers.
    private var rowMinima: [Double]
    private var rowMaxima: [Double]
    /// The dB values of every row, needed to repaint when the range moves.
    private var rowValues: [[Double]]

    // MARK: Init

    init(rowCount: Int = 200, columnCount: Int = 512) {
        self.rowCount = max(1, rowCount)
        self.columnCount = max(1, columnCount)
        self.pixels = [UInt8](repeating: 0,
                              count: self.rowCount * self.columnCount * Self.bytesPerPixel)
        self.rowMinima = []
        self.rowMaxima = []
        self.rowValues = []
    }

    // MARK: Input

    /// Adds one observation's series as the new top row.
    ///
    /// - Parameter values: the array as decoded, any length. Empty is ignored
    ///   rather than drawn as a black row — a stream that hiccups should not
    ///   leave a stripe in the history.
    mutating func append(_ values: [Double]) {
        guard !values.isEmpty else { return }

        let row = resample(values, to: columnCount)
        let decibels = Self.asDecibels(row)

        // Per-row extremes are kept incrementally rather than rescanned: at
        // 10 Hz over 200 rows of 512 bins, rescanning is a megabyte of
        // comparisons a second for an answer that changes by one row.
        let finite = decibels.filter(\.isFinite)
        rowValues.insert(decibels, at: 0)
        rowMinima.insert(finite.min() ?? 0, at: 0)
        rowMaxima.insert(finite.max() ?? 1, at: 0)
        if rowValues.count > rowCount {
            let excess = rowValues.count - rowCount
            rowValues.removeLast(excess)
            rowMinima.removeLast(excess)
            rowMaxima.removeLast(excess)
        }
        filledRows = min(filledRows + 1, rowCount)

        let previousRange = minimum...maximum
        recomputeRange()

        // A range that moved invalidates every row's colour, so the whole
        // image is repainted. It settles within a second of the stream
        // starting and then almost never fires again.
        if abs(previousRange.lowerBound - minimum) > 0.01
            || abs(previousRange.upperBound - maximum) > 0.01 {
            repaintAll()
        } else {
            shiftDown()
            paint(row: 0, decibels: decibels)
        }
    }

    /// Drops everything. Used when a card's datastream changes under it.
    mutating func reset() {
        pixels = [UInt8](repeating: 0, count: rowCount * columnCount * Self.bytesPerPixel)
        rowValues.removeAll()
        rowMinima.removeAll()
        rowMaxima.removeAll()
        filledRows = 0
        minimum = 0
        maximum = 1
    }

    // MARK: Output

    /// The buffer as an image, newest row at the top.
    ///
    /// Built through a CGDataProvider over a copy rather than a CGContext over
    /// the live array: a bitmap context's image may share the caller's buffer,
    /// and this one is about to be memmoved for the next row.
    func makeImage() -> CGImage? {
        guard filledRows > 0 else { return nil }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: columnCount,
                       height: rowCount,
                       bitsPerComponent: 8,
                       bitsPerPixel: Self.bytesPerPixel * 8,
                       bytesPerRow: columnCount * Self.bytesPerPixel,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(
                           rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                               | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    // MARK: Painting

    private mutating func shiftDown() {
        let bytesPerRow = columnCount * Self.bytesPerPixel
        let moved = (rowCount - 1) * bytesPerRow
        guard moved > 0 else { return }
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            memmove(base.advanced(by: bytesPerRow), base, moved)
        }
    }

    private mutating func repaintAll() {
        for (index, decibels) in rowValues.enumerated() where index < rowCount {
            paint(row: index, decibels: decibels)
        }
    }

    private mutating func paint(row: Int, decibels: [Double]) {
        let bytesPerRow = columnCount * Self.bytesPerPixel
        let span = max(maximum - minimum, 1e-9)
        let offset = row * bytesPerRow

        for column in 0..<columnCount {
            let value = column < decibels.count ? decibels[column] : minimum
            // A NaN or an infinity maps to the bottom of the scale rather than
            // to whatever a comparison with NaN happens to return; a bin that
            // could not be measured reads as "nothing here".
            let normalized = value.isFinite
                ? min(max((value - minimum) / span, 0), 1)
                : 0
            let colour = Viridis.colour(at: normalized)

            let index = offset + column * Self.bytesPerPixel
            pixels[index]     = colour.blue
            pixels[index + 1] = colour.green
            pixels[index + 2] = colour.red
            pixels[index + 3] = 255
        }
    }

    // MARK: Scaling

    /// Rolling range over what is still on screen, with 5% headroom so the
    /// brightest bin is not pinned to the very top of the colormap.
    private mutating func recomputeRange() {
        let lows = rowMinima.filter(\.isFinite)
        let highs = rowMaxima.filter(\.isFinite)
        guard let low = lows.min(), let high = highs.max(), low < high else {
            minimum = 0
            maximum = 1
            return
        }
        let headroom = (high - low) * 0.05
        minimum = low - headroom
        maximum = high + headroom
    }

    /// Reads the series as dB.
    ///
    /// A spectrum arrives one of two ways and the schema does not always say
    /// which. Negative values can only be a logarithmic scale already — power
    /// is never negative — so they are taken as dB; an all-positive series is
    /// treated as linear power and converted. Getting this backwards produces a
    /// waterfall that is uniformly one colour, which is at least obvious.
    static func asDecibels(_ values: [Double]) -> [Double] {
        guard values.contains(where: { $0.isFinite && $0 < 0 }) == false else { return values }
        return values.map { value in
            guard value.isFinite, value > 0 else { return -Double.infinity }
            return 10 * log10(value)
        }
    }

    /// Nearest-neighbour down to the display width.
    ///
    /// Averaging would be more correct for a photograph and is wrong here: a
    /// narrow carrier three bins wide is exactly what a user is looking for,
    /// and averaging it into 64 neighbours makes it disappear.
    private func resample(_ values: [Double], to width: Int) -> [Double] {
        guard values.count != width else { return values }
        guard values.count > width else {
            // Fewer bins than pixels: stretch, so a 64-bin spectrum still fills
            // the card.
            return (0..<width).map { column in
                values[min(column * values.count / width, values.count - 1)]
            }
        }
        // More bins than pixels: each pixel takes the strongest bin it covers,
        // which is what an SDR display does and why peaks survive zooming out.
        return (0..<width).map { column in
            let start = column * values.count / width
            let end = max(start + 1, (column + 1) * values.count / width)
            return values[start..<min(end, values.count)]
                .filter(\.isFinite)
                .max() ?? values[min(start, values.count - 1)]
        }
    }
}

// MARK: - Viridis

/// A 256-entry perceptually-uniform colormap, sampled from matplotlib's
/// viridis at nine control points and interpolated between them.
///
/// Uniform matters for a waterfall specifically: a rainbow map invents edges
/// where the data is smooth, and an operator learns to see signals that are not
/// there.
enum Viridis {

    struct Colour: Sendable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    private static let controlPoints: [(Double, Double, Double)] = [
        (0.267, 0.005, 0.329),   // 0.000
        (0.283, 0.141, 0.458),   // 0.125
        (0.254, 0.265, 0.530),   // 0.250
        (0.207, 0.372, 0.553),   // 0.375
        (0.164, 0.471, 0.558),   // 0.500
        (0.128, 0.567, 0.551),   // 0.625
        (0.135, 0.659, 0.518),   // 0.750
        (0.267, 0.749, 0.441),   // 0.875
        (0.993, 0.906, 0.144)    // 1.000
    ]

    /// The table, built once.
    static let table: [Colour] = (0..<256).map { index in
        let position = Double(index) / 255
        let scaled = position * Double(controlPoints.count - 1)
        let lower = min(Int(scaled), controlPoints.count - 2)
        let fraction = scaled - Double(lower)

        let a = controlPoints[lower]
        let b = controlPoints[lower + 1]
        func mix(_ x: Double, _ y: Double) -> UInt8 {
            UInt8(max(0, min(255, (x + (y - x) * fraction) * 255)))
        }
        return Colour(red: mix(a.0, b.0), green: mix(a.1, b.1), blue: mix(a.2, b.2))
    }

    /// The colour for a value already normalised into [0,1].
    static func colour(at position: Double) -> Colour {
        let index = Int((position * 255).rounded())
        return table[min(max(index, 0), 255)]
    }
}
