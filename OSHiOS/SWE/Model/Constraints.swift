import Foundation

// MARK: - Constraints and nil values
//
// Decode-only metadata. Nothing this app writes carries a constraint, but a
// remote schema often does — the Axis PTZ control stream bounds its pan to
// [-180, 180] and its zoom to [1, 9999] — and a value formatter or a future
// command UI needs those bounds to stay attached to the component that
// declared them.

/// Numeric constraint on a Quantity, Count or Time.
struct AllowedValues: Sendable, Equatable {
    /// An explicit enumeration of permitted values.
    var values: [Double]?
    /// Permitted closed ranges, each a two-element `[min, max]`.
    var intervals: [[Double]]?
    /// Digits of precision the writer considers meaningful.
    var significantFigures: Int?

    init(values: [Double]? = nil,
         intervals: [[Double]]? = nil,
         significantFigures: Int? = nil) {
        self.values = values
        self.intervals = intervals
        self.significantFigures = significantFigures
    }
}

/// Token constraint on a Category or Text.
struct AllowedTokens: Sendable, Equatable {
    var values: [String]?
    /// A regular expression the token must match.
    var pattern: String?

    init(values: [String]? = nil, pattern: String? = nil) {
        self.values = values
        self.pattern = pattern
    }
}

/// A reserved value standing for "no measurement", and why.
///
/// The AIS streams on the reference node use these heavily: utcSecond carries
/// nilValues for "not available", "manual input mode" and "dead reckoning", all
/// encoded as ordinary integers. Without the mapping a viewer would plot 60 as
/// a real second.
struct NilValue: Sendable, Equatable {
    let reason: String
    let value: String

    init(reason: String, value: String) {
        self.reason = reason
        self.value = value
    }
}
