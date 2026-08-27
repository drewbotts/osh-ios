import Foundation

// MARK: - DatastreamRole
//
// What a datastream *is*, inferred from its schema alone.
//
// This is the hinge of the viewer. Nothing downstream asks which driver wrote a
// stream or matches on an output name: a card, a marker, a dial or a waterfall
// is chosen because the record carries a location vector, a quaternion, an
// azimuth or a numeric array. That is what lets the app render a KrakenSDR it
// has never seen and an Android phone it has, with the same code.
//
// The rules are ordered and first-match-wins; see ROLES.md for the table and
// for how to add one.

enum DatastreamRole: Equatable, Sendable {
    /// A position, optionally with a heading to rotate its marker by.
    case location(LocationPaths, headingPath: FieldPath?)
    /// An attitude — quaternion or Euler angles.
    case orientation(OrientationPaths)
    /// A direction of arrival / line of bearing, in degrees from true north.
    case bearing(BearingPaths)
    /// Frame-sized binary, per the encoding's Block member.
    case video(compression: String?)
    /// One or more numeric DataArrays — a spectrum, a profile, a histogram.
    case chart(ChartPaths)
    /// Scalars over time: rows and sparklines.
    case timeseries
    /// Settings-flavoured. Latest value only, no history worth plotting.
    case status
    /// Understood well enough to render as rows, and nothing more specific.
    case generic

    /// Rank for "what is this system, mostly" and for which streams to open
    /// first. Higher wins.
    var priority: Int {
        switch self {
        case .video:       return 7
        case .location:    return 6
        case .orientation: return 5
        case .bearing:     return 4
        case .chart:       return 3
        case .timeseries:  return 2
        case .status:      return 1
        case .generic:     return 0
        }
    }

    /// A one-word name for the role, for badges and log lines.
    var label: String {
        switch self {
        case .location:    return "location"
        case .orientation: return "orientation"
        case .bearing:     return "bearing"
        case .video:       return "video"
        case .chart:       return "chart"
        case .timeseries:  return "timeseries"
        case .status:      return "status"
        case .generic:     return "generic"
        }
    }
}

// MARK: - OrientationPaths

/// Where an attitude lives, and how to read a compass heading out of it.
struct OrientationPaths: Equatable, Sendable {

    enum Kind: Equatable, Sendable {
        case quaternion(x: FieldPath, y: FieldPath, z: FieldPath, w: FieldPath)
        case euler(heading: FieldPath, pitch: FieldPath?, roll: FieldPath?)
    }

    let kind: Kind

    /// Heading in degrees [0,360).
    ///
    /// Euler records carry it directly. A quaternion is reduced to its yaw:
    ///
    ///     yaw = atan2(2(wz + xy), 1 − 2(y² + z²))
    ///
    /// which is the standard z-component of a ZYX Euler decomposition, then
    /// converted to degrees and wrapped. nil when the observation is missing a
    /// component or carries a non-finite one.
    func heading(from observation: ParsedObservation) -> Double? {
        switch kind {
        case .euler(let heading, _, _):
            guard let degrees = observation.values[heading]?.asDouble, degrees.isFinite else {
                return nil
            }
            return Self.normalized(degrees)

        case .quaternion(let xPath, let yPath, let zPath, let wPath):
            guard let x = observation.values[xPath]?.asDouble,
                  let y = observation.values[yPath]?.asDouble,
                  let z = observation.values[zPath]?.asDouble,
                  let w = observation.values[wPath]?.asDouble,
                  x.isFinite, y.isFinite, z.isFinite, w.isFinite else { return nil }

            let yaw = atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
            return Self.normalized(yaw * 180 / .pi)
        }
    }

    /// Pitch in degrees, when the record has one.
    func pitch(from observation: ParsedObservation) -> Double? {
        guard case .euler(_, let path?, _) = kind else { return nil }
        return observation.values[path]?.asDouble.flatMap { $0.isFinite ? $0 : nil }
    }

    /// Roll in degrees, when the record has one.
    func roll(from observation: ParsedObservation) -> Double? {
        guard case .euler(_, _, let path?) = kind else { return nil }
        return observation.values[path]?.asDouble.flatMap { $0.isFinite ? $0 : nil }
    }

    /// Wraps into [0,360). `truncatingRemainder` keeps the sign, so a negative
    /// heading — which every ±180° convention produces — needs the second step.
    static func normalized(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }
}

// MARK: - BearingPaths

/// A line of bearing: the angle, and how much to trust it.
struct BearingPaths: Equatable, Sendable {
    /// Degrees clockwise from true north.
    let angle: FieldPath
    /// Confidence, power, quality or RSSI, when the record carries one.
    let quality: FieldPath?
}

// MARK: - ChartPaths

/// The arrays a chart card plots.
struct ChartPaths: Equatable, Sendable {
    /// DataArray leaf paths carrying the y-values, in schema order.
    let series: [FieldPath]
    /// A sibling DataArray that indexes them — a frequency axis, a bin list, a
    /// time base. nil when the series are plotted against their own index.
    let xAxis: FieldPath?
}

// MARK: - DatastreamRoleInference

enum DatastreamRoleInference {

    /// Classifies one datastream.
    ///
    /// - Parameter datastreamName: the resource's name, used only by the
    ///   status rule. A node names a settings output "… Settings" far more
    ///   reliably than it defines one.
    static func role(schema: DataRecord,
                     encoding: DecodedBinaryEncoding? = nil,
                     datastreamName: String? = nil) -> DatastreamRole {

        // 1 ── video: a Block member means frames, whatever the record says.
        if let encoding, encoding.hasBinaryBlock {
            return .video(compression: encoding.blockCompression)
        }

        let leaves = SchemaWalker.leaves(of: schema)
        let settingsFlavoured = isSettingsFlavoured(schema: schema,
                                                    datastreamName: datastreamName)
        let bearing = bearingPaths(schema: schema, leaves: leaves)

        // 2 ── location.
        //
        // Two records are excluded even though a location vector resolves. A
        // settings record's position is *reported*, not observed — it is the
        // station's own fix, and rule 6 is the better description of the
        // stream; RemoteDatastream.embeddedPosition carries the position.
        //
        // A direction-finding record is excluded for the same reason: KrakenSDR
        // stamps every LOB with the station's coordinates, and a stream whose
        // subject is the bearing must render as one. Both keep their position
        // through embeddedPosition, so nothing is lost by not calling them
        // locations.
        if let resolved = LocationPaths.resolveDetailed(in: schema),
           !settingsFlavoured, bearing == nil {
            let heading = HeadingPath.resolve(in: schema, near: resolved)
            return .location(resolved.paths, headingPath: heading)
        }

        // 3 ── orientation.
        if let orientation = orientationPaths(schema: schema) {
            return .orientation(orientation)
        }

        // 4 ── bearing.
        if let bearing {
            return .bearing(bearing)
        }

        // 5 ── chart.
        if let chart = chartPaths(leaves: leaves) {
            return .chart(chart)
        }

        // 6 ── status.
        if settingsFlavoured {
            return .status
        }

        // 7 ── timeseries.
        let hasTime = leaves.contains { $0.component is TimeComponent }
        let hasNumber = leaves.contains { $0.component is Quantity || $0.component is SWECount }
        if hasTime && hasNumber {
            return .timeseries
        }

        // 8 ── generic.
        return .generic
    }

    // MARK: Rule 2/6 — settings flavour

    /// Whether a record reads as configuration rather than measurement.
    ///
    /// A weak heuristic by design, and deliberately last but for the fallback:
    /// the name test is what actually fires on the reference node, and the
    /// shape test only catches a record that is mostly sub-records with almost
    /// nothing measured at its own level.
    private static func isSettingsFlavoured(schema: DataRecord,
                                            datastreamName: String?) -> Bool {
        let haystacks = [schema.name, schema.definition, schema.label, datastreamName]
            .compactMap { $0 }
        if haystacks.contains(where: { text in
            Keywords.settings.contains { text.localizedCaseInsensitiveContains($0) }
        }) { return true }

        let nestedRecords = schema.fields.filter { $0.component is DataRecord }.count
        let topLevelQuantities = schema.fields.filter { $0.component is Quantity }.count
        return nestedRecords >= 3 && topLevelQuantities <= 1
    }

    // MARK: Rule 3 — orientation

    /// A quaternion or Euler triple, wherever it sits.
    ///
    /// Two ways in. An explicitly-defined Orientation or Quaternion container
    /// is trusted and read for whichever components it has; otherwise a Vector
    /// or record holding heading *and* pitch *and* roll is an Euler triple by
    /// construction. Requiring all three is what keeps a station heading beside
    /// a position (KrakenSDR) from reading as an attitude.
    private static func orientationPaths(schema: DataRecord) -> OrientationPaths? {
        for (fields, base, definition) in orientationContainers(of: schema) {
            let isOrientationish = definition.map { text in
                Keywords.orientation.contains { text.localizedCaseInsensitiveContains($0) }
            } ?? false

            if let quaternion = quaternionKind(fields: fields, base: base), isOrientationish {
                return OrientationPaths(kind: quaternion)
            }
            if let euler = eulerKind(fields: fields, base: base,
                                     requireAllAngles: !isOrientationish) {
                return OrientationPaths(kind: euler)
            }
        }
        return nil
    }

    /// Every record or vector in the schema, outermost first, as
    /// (fields, path, definition).
    private static func orientationContainers(
        of schema: DataRecord
    ) -> [(fields: [DataField], base: FieldPath, definition: String?)] {

        var result: [(fields: [DataField], base: FieldPath, definition: String?)] = [
            (schema.fields, FieldPath(components: []), schema.definition)
        ]
        func descend(_ fields: [DataField], _ base: FieldPath) {
            for field in fields {
                let path = base.appending(field.name)
                if let record = field.component as? DataRecord {
                    result.append((record.fields, path, record.definition))
                    descend(record.fields, path)
                } else if let vector = field.component as? SWEVector {
                    result.append((vector.coordinates, path, vector.definition))
                }
            }
        }
        descend(schema.fields, FieldPath(components: []))
        return result
    }

    /// qx/qy/qz/q0 as this app writes them, x/y/z/w as most schemas do.
    private static func quaternionKind(fields: [DataField], base: FieldPath) -> OrientationPaths.Kind? {
        func find(_ names: [String]) -> FieldPath? {
            fields.first { names.contains($0.name.lowercased()) }
                .map { base.appending($0.name) }
        }
        guard let x = find(["x", "qx", "q1"]),
              let y = find(["y", "qy", "q2"]),
              let z = find(["z", "qz", "q3"]),
              let w = find(["w", "qw", "q0", "s", "scalar"]) else { return nil }
        return .quaternion(x: x, y: y, z: z, w: w)
    }

    private static func eulerKind(fields: [DataField],
                                  base: FieldPath,
                                  requireAllAngles: Bool) -> OrientationPaths.Kind? {
        func find(definitionKeyword: String, names: [String]) -> FieldPath? {
            if let field = fields.first(where: {
                $0.component.definition?.localizedCaseInsensitiveContains(definitionKeyword) == true
            }) { return base.appending(field.name) }
            return fields.first { names.contains($0.name.lowercased()) }
                .map { base.appending($0.name) }
        }

        guard let heading = find(definitionKeyword: "Heading", names: ["heading", "yaw", "azimuth"])
        else { return nil }
        let pitch = find(definitionKeyword: "PitchAngle", names: ["pitch", "elevation"])
        let roll  = find(definitionKeyword: "RollAngle",  names: ["roll", "bank"])

        if requireAllAngles && (pitch == nil || roll == nil) { return nil }
        return .euler(heading: heading, pitch: pitch, roll: roll)
    }

    // MARK: Rule 4 — bearing

    private static func bearingPaths(schema: DataRecord,
                                     leaves: [SchemaWalker.Leaf]) -> BearingPaths? {
        let quantities = leaves.filter { $0.component is Quantity }
        guard let angle = firstLeaf(in: quantities, matchingAny: Keywords.bearing) else { return nil }

        // The quality figure has to belong to this angle, so only siblings
        // count — a confidence three records away describes something else.
        let siblings = quantities.filter {
            $0.path.components.dropLast() == angle.path.components.dropLast()
                && $0.path != angle.path
        }
        let quality = firstLeaf(in: siblings, matchingAny: Keywords.quality)
        return BearingPaths(angle: angle.path, quality: quality?.path)
    }

    // MARK: Rule 5 — chart

    /// Numeric DataArrays big enough or open-ended enough to be worth plotting.
    ///
    /// A fixed three-element array is a vector spelled oddly, not a chart; the
    /// threshold is what separates them. A variable-size array — sized by an
    /// elementCount `href` resolved per observation, as KrakenSDR's spectrum is
    /// — always qualifies, since its length is unknowable from the schema.
    private static func chartPaths(leaves: [SchemaWalker.Leaf]) -> ChartPaths? {
        let arrays = leaves.compactMap { leaf -> (path: FieldPath, array: SWEDataArray)? in
            guard let array = leaf.component as? SWEDataArray,
                  isNumeric(array.elementType) else { return nil }
            let count = array.elementCount.value
            guard count == nil || count! >= Self.minimumChartElements else { return nil }
            return (leaf.path, array)
        }
        guard !arrays.isEmpty else { return nil }

        // An axis is only an axis when there is something left to plot against
        // it; a lone frequency array is still the series.
        var xAxis: FieldPath?
        if arrays.count >= 2,
           let axisIndex = arrays.firstIndex(where: { looksLikeAxis($0.path, $0.array) }) {
            xAxis = arrays[axisIndex].path
        }
        let series = arrays.map(\.path).filter { $0 != xAxis }
        return ChartPaths(series: series, xAxis: xAxis)
    }

    private static let minimumChartElements = 8

    private static func isNumeric(_ component: DataComponent) -> Bool {
        component is Quantity || component is SWECount
    }

    private static func looksLikeAxis(_ path: FieldPath, _ array: SWEDataArray) -> Bool {
        let haystacks = [path.lastComponent, array.definition, array.label].compactMap { $0 }
        return haystacks.contains { text in
            Keywords.axis.contains { text.localizedCaseInsensitiveContains($0) }
        }
    }

    /// True when a chart's x-axis is a frequency, which is what turns a
    /// spectrum card into an SDR waterfall.
    static func isFrequencyAxis(_ path: FieldPath, in schema: DataRecord) -> Bool {
        let component = SchemaWalker.leaves(of: schema).first { $0.path == path }?.component
        let haystacks = [path.lastComponent, component?.definition, component?.label]
            .compactMap { $0 }
        return haystacks.contains {
            $0.localizedCaseInsensitiveContains("freq")
        }
    }

    // MARK: Keyword matching

    /// The first leaf matching any keyword, keywords tried in order and
    /// definitions before names.
    ///
    /// The order of the keyword list is therefore a preference list, which
    /// matters: an AIS record holds both `messageId` and `mmsi`, and only one
    /// of them identifies a vessel.
    static func firstLeaf(in leaves: [SchemaWalker.Leaf],
                          matchingAny keywords: [String]) -> SchemaWalker.Leaf? {
        for keyword in keywords {
            if let leaf = leaves.first(where: { matches($0.component.definition, keyword) }) {
                return leaf
            }
            if let leaf = leaves.first(where: { matches($0.path.lastComponent, keyword) }) {
                return leaf
            }
        }
        return nil
    }

    /// Substring for long keywords, whole-token for short ones.
    ///
    /// "lob", "doa" and "id" are three and two letters and would otherwise hit
    /// "globe", "payload" and "humidity". Splitting the identifier on
    /// separators and camelCase humps makes `raw_lob` and `messageId` match
    /// while those do not.
    private static func matches(_ text: String?, _ keyword: String) -> Bool {
        guard let text else { return false }
        if keyword.count > 4 { return text.localizedCaseInsensitiveContains(keyword) }
        return tokens(of: text).contains(keyword.lowercased())
    }

    static func tokens(of text: String) -> Set<String> {
        var tokens: Set<String> = []
        var current = ""
        var previousWasLowerOrDigit = false

        for character in text {
            if character.isLetter || character.isNumber {
                if character.isUppercase && previousWasLowerOrDigit && !current.isEmpty {
                    tokens.insert(current.lowercased())
                    current = ""
                }
                current.append(character)
                previousWasLowerOrDigit = character.isLowercase || character.isNumber
            } else {
                if !current.isEmpty { tokens.insert(current.lowercased()) }
                current = ""
                previousWasLowerOrDigit = false
            }
        }
        if !current.isEmpty { tokens.insert(current.lowercased()) }
        return tokens
    }

    // MARK: Keyword lists

    enum Keywords {
        static let settings = ["settings", "config", "status"]
        static let orientation = ["orientation", "quaternion"]
        static let bearing = ["doa", "lineofbearing", "lob", "bearing", "azimuth",
                              "angleofarrival", "aoa"]
        static let quality = ["confidence", "power", "quality", "rssi"]
        static let axis = ["frequency", "axis", "bins", "time"]
        /// Ordered strongest-first: "id" matches half the identifiers in a
        /// schema, so it only gets a turn once the specific ones have missed.
        static let entity = ["mmsi", "callsign", "icao", "tail", "identifier", "id"]
    }
}
