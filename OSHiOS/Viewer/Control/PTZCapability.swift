import Foundation

// MARK: - PTZCapability
//
// Recognising a pan/tilt/zoom camera from its command schema alone.
//
// This is the command-side counterpart to DatastreamRole, and it works the same
// way and for the same reason: nothing here asks which driver published the
// control stream. An Axis camera is offered a D-pad because its parameters are
// a DataChoice carrying a RelativePan and a RelativeTilt — so the next
// unfamiliar gimbal that says the same thing gets the same controls, and one
// that does not gets a read-only parameter tree instead of a broken joystick.
//
// Definitions are matched before names throughout. A definition is an ontology
// URI the driver author chose deliberately; a name is a JSON key that happened
// to be short. `rpan` is the reference node's spelling and is accepted, but
// `http://sensorml.com/ont/swe/property/RelativePan` is the thing that means it.
//
// Two shapes of relative movement are recognised, and a camera may offer either
// or both. The Axis camera takes a *quantity* per axis — pan by 3°, tilt by −5°.
// A second camera on the reference node takes a *name* — a Text item whose
// allowed tokens are "Up", "Down", "Left", "Right" and the four diagonals — and
// moves a fixed amount the driver decides. The D-pad is the same either way;
// what changes is the value a press sends, and whether a step size means
// anything.

struct PTZCapability: Sendable, Equatable {

    // MARK: Axis

    /// One commandable quantity: which DataChoice item selects it, and what it
    /// will accept.
    struct Axis: Sendable, Equatable {
        /// The DataChoice item name, which is the JSON key a command carries.
        let itemName: String
        /// From the component's AllowedValues, when it declares one. nil means
        /// unbounded as far as the schema says — every relative axis on the
        /// reference camera is unbounded, which is why a step size is the app's
        /// choice rather than the schema's.
        let range: ClosedRange<Double>?
        /// From a Text item's AllowedTokens, when it declares them: the preset
        /// names a camera will actually accept. nil when the schema leaves the
        /// vocabulary open, which is when a free-text field is honest.
        let tokens: [String]?

        init(itemName: String, range: ClosedRange<Double>? = nil, tokens: [String]? = nil) {
            self.itemName = itemName
            self.range = range
            self.tokens = tokens
        }
    }

    // MARK: Named moves

    /// Relative movement by name: one Text item whose allowed tokens are
    /// directions, and which token means which direction.
    ///
    /// The tokens are kept exactly as the schema spells them — "TopLeft", not
    /// a normalised form — because that spelling is what the camera accepts.
    struct NamedMoves: Sendable, Equatable {
        enum Direction: CaseIterable, Sendable {
            case up, down, left, right
            case upLeft, upRight, downLeft, downRight

            var isDiagonal: Bool {
                switch self {
                case .up, .down, .left, .right: return false
                default:                        return true
                }
            }
        }

        let itemName: String
        let tokens: [Direction: String]

        /// The token to send for a direction, or nil when the camera has none.
        func token(for direction: Direction) -> String? { tokens[direction] }

        /// A pad needs all four cardinal moves; a camera offering only
        /// "Left" and "Right" is a panner, not a PTZ.
        var supportsDPad: Bool {
            tokens[.up] != nil && tokens[.down] != nil
                && tokens[.left] != nil && tokens[.right] != nil
        }

        var hasDiagonals: Bool { tokens.keys.contains { $0.isDiagonal } }
    }

    // MARK: Position record

    /// The combined absolute move — `ptzPos` on the reference camera.
    ///
    /// Modelled apart from the individual absolute axes because it is a
    /// different command: sending pan, then tilt, then zoom is three moves the
    /// camera performs one after another, and sending the record is one. When a
    /// camera offers both, the record is what "Go" should use.
    struct PositionRecord: Sendable, Equatable {
        let itemName: String
        let pan: Axis
        let tilt: Axis
        let zoom: Axis
    }

    // MARK: Members

    let controlStreamId: String

    let relativePan: Axis?
    let relativeTilt: Axis?
    let relativeZoom: Axis?

    let absolutePan: Axis?
    let absoluteTilt: Axis?
    let absoluteZoom: Axis?

    /// A Text item naming a stored camera position.
    let preset: Axis?

    /// The combined absolute record, when the schema offers one.
    let position: PositionRecord?

    /// Relative movement by direction name, when the schema offers it.
    let namedMoves: NamedMoves?

    init(controlStreamId: String,
         relativePan: Axis? = nil,
         relativeTilt: Axis? = nil,
         relativeZoom: Axis? = nil,
         absolutePan: Axis? = nil,
         absoluteTilt: Axis? = nil,
         absoluteZoom: Axis? = nil,
         preset: Axis? = nil,
         position: PositionRecord? = nil,
         namedMoves: NamedMoves? = nil) {
        self.controlStreamId = controlStreamId
        self.relativePan = relativePan
        self.relativeTilt = relativeTilt
        self.relativeZoom = relativeZoom
        self.absolutePan = absolutePan
        self.absoluteTilt = absoluteTilt
        self.absoluteZoom = absoluteZoom
        self.preset = preset
        self.position = position
        self.namedMoves = namedMoves
    }

    /// Both quantity axes, or a full set of named directions; one relative
    /// axis alone is a slider, not a pad.
    var supportsDPad: Bool { supportsQuantityDPad || namedMoves?.supportsDPad == true }

    /// True when a pad press sends a number of degrees, which is the only
    /// case a step size applies to.
    var supportsQuantityDPad: Bool { relativePan != nil && relativeTilt != nil }

    /// True when anything at all can be driven absolutely.
    var supportsAbsolute: Bool {
        position != nil || absolutePan != nil || absoluteTilt != nil || absoluteZoom != nil
    }

    // MARK: Detection

    /// Recognises a PTZ camera in a control stream's parameters schema.
    ///
    /// - Parameter schema: the paramsSchema root. Either the DataChoice itself
    ///   or the single-field record SWESchemaDecoder wraps a non-record root
    ///   in — both arrive here depending on how the caller decoded, and
    ///   rejecting one of them would make detection depend on a wrapper.
    /// - Returns: nil unless the schema offers a *pair* of pan and tilt axes
    ///   — relative or absolute — or a named-move item with all four cardinal
    ///   directions. A lone zoom control is a zoom control; calling it a PTZ
    ///   camera and drawing a D-pad for it would be a lie the user discovers
    ///   by pressing a button that does nothing.
    static func detect(in schema: DataComponent,
                       controlStreamId: String) -> PTZCapability? {

        guard let choice = dataChoice(in: schema) else { return nil }

        var relativePan: Axis?, relativeTilt: Axis?, relativeZoom: Axis?
        var absolutePan: Axis?, absoluteTilt: Axis?, absoluteZoom: Axis?
        var preset: Axis?
        var position: PositionRecord?
        var namedMoves: NamedMoves?

        for item in choice.items {
            if let record = item.component as? DataRecord {
                position = position ?? positionRecord(named: item.name, record: record)
                continue
            }

            let text = item.component as? SWEText
            let axis = Axis(itemName: item.name,
                            range: range(of: item.component),
                            tokens: text?.constraint?.values)
            let definition = item.component.definition
            let name = item.name.lowercased()

            // Relative first: "RelativePan" contains "Pan", so testing the
            // absolute rules first would swallow every relative axis.
            if relativePan == nil, matches(definition, "RelativePan", name, ["rpan"]) {
                relativePan = axis
            } else if relativeTilt == nil, matches(definition, "RelativeTilt", name, ["rtilt"]) {
                relativeTilt = axis
            } else if relativeZoom == nil, matches(definition, "RelativeZoom", name, ["rzoom"]) {
                relativeZoom = axis
            } else if namedMoves == nil, let text,
                      let moves = Self.namedMoves(named: item.name, text: text) {
                // Before the preset rule: both are Text items, and a token list
                // of directions is the stronger evidence of the two.
                namedMoves = moves
            } else if preset == nil, item.component is SWEText,
                      matches(definition, "Preset", name, ["preset"]) {
                preset = axis
            } else if absolutePan == nil, matchesAbsolute(definition, "Pan", name, ["pan"]) {
                absolutePan = axis
            } else if absoluteTilt == nil, matchesAbsolute(definition, "Tilt", name, ["tilt"]) {
                absoluteTilt = axis
            } else if absoluteZoom == nil, matchesAbsolute(definition, "ZoomFactor", name, ["zoom"]) {
                absoluteZoom = axis
            }
        }

        let hasRelativePair = relativePan != nil && relativeTilt != nil
        let hasAbsolutePair = (absolutePan != nil && absoluteTilt != nil) || position != nil
        let hasNamedPad = namedMoves?.supportsDPad == true
        guard hasRelativePair || hasAbsolutePair || hasNamedPad else { return nil }

        return PTZCapability(controlStreamId: controlStreamId,
                             relativePan: relativePan,
                             relativeTilt: relativeTilt,
                             relativeZoom: relativeZoom,
                             absolutePan: absolutePan,
                             absoluteTilt: absoluteTilt,
                             absoluteZoom: absoluteZoom,
                             preset: preset,
                             position: position,
                             namedMoves: namedMoves)
    }

    // MARK: Named moves

    /// A Text item is a set of named moves when it says so — by definition
    /// (`RelativeMovement`) or, with no definition, by name — *and* its allowed
    /// tokens read as directions. Both are required: a "relMove" with no token
    /// list gives the app nothing it could send, and a token list of
    /// directions on an item called "mode" is a coincidence the definition
    /// should have to confirm.
    ///
    /// Tokens are read for the words in them rather than matched exactly, so
    /// "Up", "TopLeft", "BOTTOM_RIGHT" and "up-left" all land: `top` and `up`
    /// mean up, `bottom` and `down` mean down, and a token carrying both a
    /// vertical and a horizontal word is a diagonal.
    static func namedMoves(named itemName: String, text: SWEText) -> NamedMoves? {
        let definition = text.definition
        let name = itemName.lowercased()
        guard matches(definition, "RelativeMovement", name, ["relmove", "move", "movement", "direction"]),
              let values = text.constraint?.values, !values.isEmpty else { return nil }

        var tokens: [NamedMoves.Direction: String] = [:]
        for token in values {
            guard let direction = direction(of: token), tokens[direction] == nil else { continue }
            tokens[direction] = token
        }
        // At least one real move, or the token list was about something else.
        guard !tokens.isEmpty else { return nil }
        return NamedMoves(itemName: itemName, tokens: tokens)
    }

    private static func direction(of token: String) -> NamedMoves.Direction? {
        let word = token.lowercased()
        let up = word.contains("up") || word.contains("top")
        let down = word.contains("down") || word.contains("bottom")
        let left = word.contains("left")
        let right = word.contains("right")

        // A token that says two opposite things is not a direction.
        guard !(up && down), !(left && right) else { return nil }

        switch (up, down, left, right) {
        case (true, false, false, false):  return .up
        case (false, true, false, false):  return .down
        case (false, false, true, false):  return .left
        case (false, false, false, true):  return .right
        case (true, false, true, false):   return .upLeft
        case (true, false, false, true):   return .upRight
        case (false, true, true, false):   return .downLeft
        case (false, true, false, true):   return .downRight
        default:                           return nil
        }
    }

    // MARK: Structure

    /// The DataChoice at the root, or in a top-level field.
    ///
    /// The second case is the ordinary one: SWESchemaDecoder wraps a non-record
    /// root in a single-field DataRecord so that decoded values land at the
    /// paths a payload actually carries.
    static func dataChoice(in schema: DataComponent) -> SWEDataChoice? {
        if let choice = schema as? SWEDataChoice { return choice }
        guard let record = schema as? DataRecord else { return nil }
        for field in record.fields {
            if let choice = field.component as? SWEDataChoice { return choice }
        }
        return nil
    }

    /// A record of three absolute axes, when its fields say so.
    private static func positionRecord(named itemName: String,
                                       record: DataRecord) -> PositionRecord? {
        func axis(_ keyword: String, _ names: [String]) -> Axis? {
            for field in record.fields {
                guard matchesAbsolute(field.component.definition, keyword,
                                      field.name.lowercased(), names) else { continue }
                return Axis(itemName: field.name, range: range(of: field.component))
            }
            return nil
        }
        guard let pan = axis("Pan", ["pan"]),
              let tilt = axis("Tilt", ["tilt"]),
              let zoom = axis("ZoomFactor", ["zoom"]) else { return nil }
        return PositionRecord(itemName: itemName, pan: pan, tilt: tilt, zoom: zoom)
    }

    // MARK: Matching

    private static func matches(_ definition: String?,
                                _ keyword: String,
                                _ name: String,
                                _ names: [String]) -> Bool {
        if let definition, definition.localizedCaseInsensitiveContains(keyword) { return true }
        // Only when the definition says nothing: a definition that exists and
        // disagrees is the author being explicit, and a name should not
        // override it.
        return definition == nil && names.contains(name)
    }

    /// As `matches`, but refuses anything the schema calls relative.
    private static func matchesAbsolute(_ definition: String?,
                                        _ keyword: String,
                                        _ name: String,
                                        _ names: [String]) -> Bool {
        if let definition {
            guard !definition.localizedCaseInsensitiveContains("Relative") else { return false }
            return definition.localizedCaseInsensitiveContains(keyword)
        }
        return names.contains(name)
    }

    // MARK: Ranges

    /// The first AllowedValues interval, as a Swift range.
    ///
    /// Only the first: a component with several disjoint intervals cannot drive
    /// one slider, and pretending the union is a range would let the UI offer
    /// values the camera will refuse.
    static func range(of component: DataComponent) -> ClosedRange<Double>? {
        guard let interval = constraint(of: component)?.intervals?.first,
              interval.count >= 2 else { return nil }
        let lower = min(interval[0], interval[1])
        let upper = max(interval[0], interval[1])
        guard lower < upper else { return nil }
        return lower...upper
    }

    private static func constraint(of component: DataComponent) -> AllowedValues? {
        if let quantity = component as? Quantity { return quantity.constraint }
        if let count = component as? SWECount { return count.constraint }
        if let time = component as? SWETime { return time.constraint }
        return nil
    }
}
