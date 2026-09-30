import Foundation

// MARK: - SurveyWriteStrategy
//
// Where a surveyed position goes on the node, decided by what the system is.
//
// A system a driver module registered — the Axis cameras on the reference node —
// cannot have its SensorML description edited through the API (the node answers
// 404), but its driver publishes the configured emplacement as two ordinary
// outputs: `sensorLocation` (a lat/lon/alt vector in EPSG 4979) and
// `sensorOrientation` (heading/pitch/roll in NED, "the platform orientation
// when the PTZ is at (0, 0, 0)"). Each holds the value that was typed into the
// driver's configuration, published once when it was configured and not
// republished on a restart. A new observation on those streams *is* a new
// emplacement, and it is what the node's own viewer reads.
//
// A system with no such outputs gets them: the two datastreams are created on
// it in the driver's own shape (SurveyOutputSchemas) and then written to the
// same way. Never the system description — a PUT there replaces the whole
// SensorML document, and the node refuses it for any system a driver owns.
//
// Either way the write reaches the node only if the system is in the API's
// *write* database. On OpenSensorHub 2.0 a driver's system lives there only
// when the Connected Systems Database module lists the system's UID (or a
// wildcard matching it) under "System UIDs"; otherwise the node answers
// "Resource is not writable" for an observation and 404 or 500 for a new
// datastream. That is node configuration, and the failure screen says so.

enum SurveyWriteStrategy: Equatable, Sendable {

    /// Post observations to the driver's static outputs.
    case staticOutputs(location: RemoteDatastream, orientation: RemoteDatastream?)
    /// Create `sensorLocation` and `sensorOrientation` on the system, then post.
    case createOutputs

    static func == (lhs: SurveyWriteStrategy, rhs: SurveyWriteStrategy) -> Bool {
        switch (lhs, rhs) {
        case (.createOutputs, .createOutputs):
            return true
        case (.staticOutputs(let l1, let o1), .staticOutputs(let l2, let o2)):
            return l1.id == l2.id && o1?.id == o2?.id
        default:
            return false
        }
    }

    // MARK: Vocabulary

    static let sensorLocationDefinition = "http://www.opengis.net/def/property/OGC/0/SensorLocation"
    static let sensorOrientationDefinition = "http://www.opengis.net/def/property/OGC/0/SensorOrientation"
    static let sensorLocationName = "sensorLocation"
    static let sensorOrientationName = "sensorOrientation"

    // MARK: Detection

    /// The strategy for `system`.
    ///
    /// The location output is required for `.staticOutputs`; the orientation
    /// one is taken when present. Both are matched by their vector's
    /// definition first and by exact output name second, and the orientation
    /// match is the one that has to be careful: the Axis also publishes
    /// `sensorOrientationPtz`, the *live* pointing direction computed from the
    /// PTZ position, under the very same SensorOrientation definition. Writing
    /// a mount orientation there would be wrong twice over, so the name breaks
    /// the tie — and a system offering only the PTZ stream gets no orientation
    /// write at all.
    static func detect(for system: RemoteSystem) -> SurveyWriteStrategy {
        guard let location = staticOutput(in: system.locationDatastreams,
                                          definition: sensorLocationDefinition,
                                          name: sensorLocationName,
                                          vectorName: "location") else {
            return .createOutputs
        }
        let orientationStreams = system.datastreams.filter {
            if case .orientation(let paths) = $0.role, case .euler = paths.kind { return true }
            return false
        }
        let orientation = staticOutput(in: orientationStreams,
                                       definition: sensorOrientationDefinition,
                                       name: sensorOrientationName,
                                       vectorName: "orientation")
        return .staticOutputs(location: location, orientation: orientation)
    }

    /// The one datastream in `candidates` that is the driver's static output.
    ///
    /// Exact output name wins outright. Failing that, a single candidate whose
    /// vector carries the definition is taken — unless its name says it is a
    /// live pointing stream (`ptz`, `current`, `live`, `dynamic`): the Axis
    /// driver's `sensorOrientationPtz` carries the SensorOrientation definition
    /// too, and a camera offering only that has no static orientation to
    /// write. Two or more candidates sharing the definition and none with the
    /// name is ambiguous, and ambiguity means no write rather than a guess.
    private static func staticOutput(in candidates: [RemoteDatastream],
                                     definition: String,
                                     name: String,
                                     vectorName: String) -> RemoteDatastream? {
        let decodable = candidates.filter { $0.decoder != nil && $0.recordSchema != nil }
        if let named = decodable.first(where: { $0.summary.outputName == name }) {
            return named
        }
        let defined = decodable.filter { datastream in
            guard let record = datastream.recordSchema else { return false }
            let outputName = (datastream.summary.outputName ?? datastream.name).lowercased()
            guard !liveMarkers.contains(where: { outputName.contains($0) }) else { return false }
            return record.fields.contains { field in
                (field.component as? SWEVector)?.definition == definition
            }
        }
        return defined.count == 1 ? defined[0] : nil
    }

    /// Words in an output name that mean "computed from the current state",
    /// not "the emplacement".
    private static let liveMarkers = ["ptz", "current", "live", "dynamic"]

    // MARK: Describing

    /// What the review screen says will be written.
    var summary: String {
        switch self {
        case .createOutputs:
            return "new sensorLocation and sensorOrientation outputs on the system"
        case .staticOutputs(let location, let orientation):
            if let orientation {
                return "the \(location.name) and \(orientation.name) outputs"
            }
            return "the \(location.name) output (no static orientation output)"
        }
    }
}

// MARK: - SurveyObservationBody

/// One swe+json observation for a static output, built from the output's own
/// schema.
///
/// The body is the record's leaves in schema order — `time` first, then the
/// vector's coordinates under the vector's name — with values looked up by leaf
/// *name*, so `lat`/`lon`/`alt` and `heading`/`pitch`/`roll` come from the
/// schema the node served rather than from anything this app assumes.
///
/// Its own builder rather than ConnectedSystemsClient's: the schema decoder
/// yields `SWETime` for a Time field, which the publisher's builder does not
/// handle (it knows only the `TimeStamp` this app writes for itself) and would
/// silently drop — and the publishing path is not to be touched.
enum SurveyObservationBody {

    enum BodyError: Error, LocalizedError, Equatable {
        case missingValue(path: String)
        case unsupportedComponent(path: String, type: String)

        var errorDescription: String? {
            switch self {
            case .missingValue(let path):
                return "No survey value for schema field \(path)"
            case .unsupportedComponent(let path, let type):
                return "Schema field \(path) is a \(type), which a survey cannot fill"
            }
        }
    }

    /// - Parameters:
    ///   - schema: the datastream's decoded `recordSchema`.
    ///   - time: written into every Time leaf, ISO 8601 with milliseconds.
    ///   - values: by leaf name (`"lat"`, `"heading"`, …). Every non-time leaf
    ///     must have one; a leaf the survey has nothing for is an error, not a
    ///     zero the node would store as a measurement.
    static func build(schema: DataRecord, time: Date, values: [String: Double]) throws -> String {
        var out = "{"
        try writeFields(schema.fields, path: [], time: time, values: values, into: &out)
        out += "}"
        return out
    }

    private static func writeFields(_ fields: [DataField],
                                    path: [String],
                                    time: Date,
                                    values: [String: Double],
                                    into out: inout String) throws {
        for (index, field) in fields.enumerated() {
            if index > 0 { out += "," }
            out += CommandBody.string(field.name) + ":"
            let fieldPath = path + [field.name]
            switch field.component {
            case is SWETime, is TimeStamp:
                out += CommandBody.string(CommandBody.isoFormatter.string(from: time))

            case let vector as SWEVector:
                out += "{"
                try writeFields(vector.coordinates, path: fieldPath, time: time,
                                values: values, into: &out)
                out += "}"

            case let record as DataRecord:
                out += "{"
                try writeFields(record.fields, path: fieldPath, time: time,
                                values: values, into: &out)
                out += "}"

            case is Quantity, is SWECount:
                guard let value = values[field.name] else {
                    throw BodyError.missingValue(path: fieldPath.joined(separator: "/"))
                }
                out += CommandBody.number(value)

            default:
                throw BodyError.unsupportedComponent(path: fieldPath.joined(separator: "/"),
                                                     type: String(describing: type(of: field.component)))
            }
        }
    }

    /// The location body for a pose: every coordinate of the location vector
    /// by its schema name, from the survey's lat/lon/HAE.
    static func location(schema: DataRecord, pose: SurveyedPose, time: Date) throws -> String {
        try build(schema: schema, time: time, values: [
            "lat": pose.latitude, "latitude": pose.latitude,
            "lon": pose.longitude, "longitude": pose.longitude,
            "alt": pose.heightAboveEllipsoid, "altitude": pose.heightAboveEllipsoid,
            "h": pose.heightAboveEllipsoid, "height": pose.heightAboveEllipsoid
        ])
    }

    /// The orientation body for a pose.
    static func orientation(schema: DataRecord, pose: SurveyedPose, time: Date) throws -> String {
        try build(schema: schema, time: time, values: [
            "heading": pose.yaw, "yaw": pose.yaw, "azimuth": pose.yaw,
            "pitch": pose.pitch, "elevation": pose.pitch,
            "roll": pose.roll, "bank": pose.roll
        ])
    }
}
