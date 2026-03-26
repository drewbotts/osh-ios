import Foundation

// MARK: - ConnectedSystemsClient
//
// URLSession-based HTTP client for the OGC Connected Systems API.
//
// Base URL:  http(s)://<host>:<port>/<path>/  (e.g. http://host:8181/sensorhub/api/)
// Auth:      HTTP Basic (Base64 encoded username:password in Authorization header)
//
// All methods are async/await.
//
// Endpoint layout (from ConSysApiClient.java constants):
//   POST /systems                        → register a system, returns system id
//   POST /systems/{id}/datastreams       → register a datastream, returns datastream id
//   POST /datastreams/{id}/observations  → post an observation

actor ConnectedSystemsClient {

    private let baseURL: URL
    private let authHeader: String
    private let session: URLSession

    // MARK: Init

    init(nodeURL: String, username: String, password: String) throws {
        guard let url = URL(string: nodeURL.hasSuffix("/") ? nodeURL : nodeURL + "/") else {
            throw ClientError.invalidURL(nodeURL)
        }
        self.baseURL = url

        let cred = "\(username):\(password)"
            .data(using: .utf8)!
            .base64EncodedString()
        self.authHeader = "Basic \(cred)"

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 30
        config.timeoutIntervalForResource = 60
        // NoRedirectDelegate prevents URLSession from following HTTP redirects.
        // The OSH server redirects 404 errors to its admin error page, which in turn
        // redirects to /sensorhub and returns 401 — masking the real status code.
        self.session = URLSession(configuration: config,
                                  delegate: NoRedirectDelegate(),
                                  delegateQueue: nil)
    }

    // MARK: - System registration
    //
    // POST /systems  with SensorML-JSON body
    // On success the response Location header contains the new system URL;
    // we parse the last path component as the id.
    // Returns the system resource id string.

    func registerSystem(_ descriptor: SystemDescriptor) async throws -> String {
        let url = baseURL.appendingPathComponent("systems")
        let body = try descriptor.toJSONData()
        let response = try await post(url: url, body: body, contentType: "application/sml+json")
        guard let id = response.locationId else {
            throw ClientError.missingLocation("POST /systems returned no Location header")
        }
        return id
    }

    // MARK: - Datastream registration
    //
    // POST /systems/{systemId}/datastreams  with SWE-JSON schema body
    // Returns the datastream resource id.

    func registerDatastream(
        systemId: String,
        name: String,
        schema: DataRecord,
        encoding: BinaryEncoding
    ) async throws -> String {
        let url = baseURL
            .appendingPathComponent("systems")
            .appendingPathComponent(systemId)
            .appendingPathComponent("datastreams")

        let jsonString = buildDatastreamJSON(name: name, schema: schema, encoding: encoding)
        guard let body = jsonString.data(using: .utf8) else {
            throw ClientError.encodingFailed
        }
        let response = try await post(url: url, body: body, contentType: "application/json")
        guard let id = response.locationId else {
            throw ClientError.missingLocation("POST /systems/\(systemId)/datastreams returned no Location header")
        }
        return id
    }

    // MARK: - Post observation
    //
    // POST /datastreams/{datastreamId}/observations
    // Scalar (GPS, orientation): O&M JSON  →  application/om+json
    // Video:                     SWE binary →  application/swe+binary

    func postObservation(datastreamId: String, observation: Observation, schema: DataRecord?) async throws {
        let url = baseURL
            .appendingPathComponent("datastreams")
            .appendingPathComponent(datastreamId)
            .appendingPathComponent("observations")

        switch observation.payload {
        case .scalar(let values):
            let body = try buildScalarObsJSON(values: values, schema: schema)
            try await postRaw(url: url, body: body, contentType: "application/swe+json")

        case .video(let timestamp, let frame):
            let body = buildBinaryObsBody(timestamp: timestamp, frame: frame)
            try await postRaw(url: url, body: body, contentType: "application/swe+binary")
        }
    }

    // MARK: - JSON builders
    //
    // All JSON is built as ordered strings because the server's Gson streaming parser
    // requires "type" to be the FIRST key in every object.  Swift Dictionary and
    // [String: Any] do not guarantee insertion-order serialisation.

    /// Builds the datastream registration JSON body as an ordered string.
    ///
    /// Scalar streams (GPS, orientation, barometer, audio):
    ///   "schema": { "obsFormat":"application/swe+json", "recordSchema":{...} }
    ///   • Full schema including time field
    ///
    /// Video streams (H264) — mirrors Android VideoCamHelper.newVideoOutputCODEC:
    ///   "schema": { "obsFormat":"application/swe+binary", "recordSchema":{...}, "recordEncoding":{...} }
    ///   • recordSchema: DataRecord with time + img DataArray (full pixel structure)
    ///   • recordEncoding: BinaryEncoding — /time=scalar double, /img=BinaryBlock(codec)
    ///   • Wire format: 8-byte big-endian Double timestamp + compressed frame bytes
    private func buildDatastreamJSON(
        name: String,
        schema: DataRecord,
        encoding: BinaryEncoding
    ) -> String {
        let isVideo = encoding.fields.contains { if case .block = $0.type { return true }; return false }

        var s = "{"
        s += jkv("name", name)
        s += "," + jkv("outputName", name)
        s += "," + jq("schema") + ":{"

        if isVideo {
            // Video: SWE binary format.
            // recordSchema = DataRecord with time + img DataArray (pixel structure).
            // recordEncoding maps "/time" to scalar double and "/img" to a BinaryBlock
            // with the codec compression — so the actual wire bytes are:
            //   8-byte big-endian Double timestamp + compressed frame bytes.
            // This mirrors Android VideoCamHelper.newVideoOutputCODEC exactly.
            s += jkv("obsFormat", "application/swe+binary")
            s += "," + jq("recordSchema") + ":" + sweRecordToJSON(schema, rootLevel: true)
            s += "," + jq("recordEncoding") + ":" + binaryEncodingToJSON(encoding)
        } else {
            // Scalar: SWE+JSON format; full schema including time field, no encoding block.
            // Root DataRecord has no "name" field (server infers from outputName).
            s += jkv("obsFormat", "application/swe+json")
            s += "," + jq("recordSchema") + ":" + sweRecordToJSON(schema, rootLevel: true)
        }

        s += "}"
        s += "}"
        return s
    }

    /// Serialises a DataRecord as a SWE-JSON object.
    ///
    /// Top-level format (used for recordSchema root):
    ///   { "type":"DataRecord", "name":"gps_data", ... "fields":[...] }
    ///
    /// Each field (and each coordinate inside a Vector) is written flat — no
    /// "component" wrapper — with "type" FIRST, then "name", then other properties.
    /// The OSH Gson streaming parser requires "type" as the first key everywhere.
    /// - rootLevel: when true (top-level recordSchema), omits "name" and "label" —
    ///   the server derives the name from the datastream outputName.
    private func sweRecordToJSON(_ record: DataRecord, rootLevel: Bool = false) -> String {
        var s = "{"
        s += jkv("type", "DataRecord")
        if !rootLevel { s += "," + jkv("name", record.name) }
        if let def = record.definition { s += "," + jkv("definition", def) }
        if !rootLevel, let lbl = record.label { s += "," + jkv("label", lbl) }
        s += "," + jq("fields") + ":["
        s += record.fields.map { sweFieldToJSON($0) }.joined(separator: ",")
        s += "]}"
        return s
    }

    /// Serialises a DataField as a flat SWE-JSON component object:
    ///   { "type":"<T>", "name":"<fieldName>", ...component properties... }
    private func sweFieldToJSON(_ field: DataField) -> String {
        sweComponentToJSON(field.component, name: field.name)
    }

    /// Serialises a DataComponent with "type" first, then "name", then properties.
    /// The name parameter is the containing field's or coordinate's name.
    private func sweComponentToJSON(_ component: DataComponent, name: String) -> String {
        switch component {
        case let t as TimeStamp:
            var s = "{"
            s += jkv("type", "Time")
            s += "," + jkv("name", name)
            if let def = t.definition { s += "," + jkv("definition", def) }
            if let lbl = t.label      { s += "," + jkv("label", lbl) }
            if let rf  = t.refFrame   { s += "," + jkv("referenceFrame", rf) }
            if let href = t.uomHref   { s += "," + jq("uom") + ":{" + jkv("href", href) + "}" }
            s += "}"
            return s

        case let q as Quantity:
            var s = "{"
            s += jkv("type", "Quantity")
            s += "," + jkv("name", name)
            if let def  = q.definition  { s += "," + jkv("definition", def) }
            if let lbl  = q.label       { s += "," + jkv("label", lbl) }
            if let desc = q.description { s += "," + jkv("description", desc) }
            if let axis = q.axisId      { s += "," + jkv("axisID", axis) }
            if let rf   = q.refFrame    { s += "," + jkv("referenceFrame", rf) }
            s += "," + jq("uom") + ":{" + jkv("code", q.uom) + "}"
            s += "}"
            return s

        case let v as SWEVector:
            var s = "{"
            s += jkv("type", "Vector")
            s += "," + jkv("name", name)
            if let def  = v.definition  { s += "," + jkv("definition", def) }
            if let lbl  = v.label       { s += "," + jkv("label", lbl) }
            if let desc = v.description { s += "," + jkv("description", desc) }
            if let rf   = v.refFrame    { s += "," + jkv("referenceFrame", rf) }
            if let lf   = v.localFrame  { s += "," + jkv("localFrame", lf) }
            s += "," + jq("coordinates") + ":["
            s += v.coordinates.map { sweFieldToJSON($0) }.joined(separator: ",")
            s += "]}"
            return s

        case let dr as DataRecord:
            var s = "{"
            s += jkv("type", "DataRecord")
            s += "," + jkv("name", name)
            if let def = dr.definition { s += "," + jkv("definition", def) }
            if let lbl = dr.label      { s += "," + jkv("label", lbl) }
            s += "," + jq("fields") + ":["
            s += dr.fields.map { sweFieldToJSON($0) }.joined(separator: ",")
            s += "]}"
            return s

        case let arr as SWEDataArray:
            var s = "{"
            s += jkv("type", "DataArray")
            s += "," + jkv("name", name)
            if let def = arr.definition { s += "," + jkv("definition", def) }
            // elementCount — inline Count object (no name; has axisID and value)
            s += "," + jq("elementCount") + ":{"
            s += jkv("type", "Count")
            if let def  = arr.elementCount.definition { s += "," + jkv("definition", def) }
            if let axis = arr.elementCount.axisID     { s += "," + jkv("axisID", axis) }
            if let val  = arr.elementCount.value      { s += "," + "\(jq("value")):\(val)" }
            s += "}"
            // elementType — recursive component with its own name
            s += "," + jq("elementType") + ":" + sweComponentToJSON(arr.elementType, name: arr.elementTypeName)
            s += "}"
            return s

        case let c as SWECount:
            // Count used as a named field (e.g. red/green/blue channel)
            var s = "{"
            s += jkv("type", "Count")
            s += "," + jkv("name", name)
            if let def = c.definition { s += "," + jkv("definition", def) }
            s += "}"
            return s

        default:
            var s = "{"
            s += jkv("type", "Text")
            s += "," + jkv("name", name)
            s += "}"
            return s
        }
    }

    private func binaryEncodingToJSON(_ enc: BinaryEncoding) -> String {
        var s = "{"
        s += jkv("type", "BinaryEncoding")
        s += "," + jkv("byteOrder", enc.byteOrder)
        s += "," + jkv("byteEncoding", enc.byteEncoding)
        s += "," + jq("members") + ":["
        s += enc.fields.map { field -> String in
            var m = "{"
            switch field.type {
            case .scalar(let dt):
                m += jkv("type", "Component")
                m += "," + jkv("ref", field.ref)
                m += "," + jkv("dataType", dt.rawValue)
            case .block(let codec):
                m += jkv("type", "Block")
                m += "," + jkv("ref", field.ref)
                m += "," + jkv("compression", codec)
            }
            m += "}"
            return m
        }.joined(separator: ",")
        s += "]}"
        return s
    }

    // MARK: - JSON string helpers

    /// Quoted JSON key.
    private func jq(_ key: String) -> String { "\"\(key)\"" }

    /// Minimal JSON string escaping.
    private func jEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Key-value pair: `"key":"value"`.
    private func jkv(_ key: String, _ value: String) -> String {
        "\(jq(key)):\(jq(jEscape(value)))"
    }

    /// Builds an O&M JSON observation body for scalar sensors (GPS, orientation).
    ///
    /// Format:  { "phenomenonTime": "<ISO8601>", "result": { ... } }
    /// values[0] is the Unix timestamp (→ phenomenonTime).
    /// values[1…] are mapped to a nested result object that mirrors the registered
    /// resultSchema (time field excluded), e.g.:
    ///   GPS        → { "location": { "lat": …, "lon": …, "alt": … } }
    ///   Euler      → { "orient":   { "heading": …, "pitch": …, "roll": … } }
    ///   Quaternion → { "orient":   { "qx": …, "qy": …, "qz": …, "q0": … } }
    /// Builds an O&M JSON observation as an ordered string.
    ///
    /// The Gson streaming parser on the server requires JSON object keys in the exact
    /// schema-defined order — Swift Dictionary / JSONSerialization do not guarantee
    /// this, so we build the JSON string directly.
    ///
    /// Example output (GPS):
    ///   {"phenomenonTime":"2024-…","result":{"location":{"lat":37.5,"lon":-122.0,"alt":100.0}}}
    /// Builds a SWE+JSON observation body.
    ///
    /// For application/swe+json the body is the raw data object — no O&M envelope.
    /// Field order matches the recordSchema exactly so the streaming parser can read
    /// each field by name in sequence.
    ///
    /// Example (GPS): {"time":1234567890.123,"location":{"lat":37.5,"lon":-122.0,"alt":100.0}}
    private func buildScalarObsJSON(values: [Double], schema: DataRecord?) throws -> Data {
        guard !values.isEmpty else { throw ClientError.emptyPayload }

        let s: String
        if let schema = schema {
            s = buildResultJSON(schema: schema, values: values)
        } else {
            // Fallback (no schema): flat array
            s = "[" + values.map { String($0) }.joined(separator: ",") + "]"
        }

        guard let data = s.data(using: .utf8) else { throw ClientError.encodingFailed }
        return data
    }

    /// Traverses the DataRecord schema and serialises values in schema-defined order.
    /// All fields including time are included; values[0] maps to the time field.
    private func buildResultJSON(schema: DataRecord, values: [Double]) -> String {
        var s = "{"
        var idx = 0
        var firstField = true
        for field in schema.fields {
            if !firstField { s += "," }
            firstField = false
            switch field.component {
            case is TimeStamp:
                if idx < values.count {
                    let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: values[idx]))
                    s += jq(field.name) + ":" + jq(iso)
                    idx += 1
                }
            case let vec as SWEVector:
                s += jq(field.name) + ":{"
                var firstCoord = true
                for coord in vec.coordinates where idx < values.count {
                    if !firstCoord { s += "," }
                    firstCoord = false
                    s += jq(coord.name) + ":\(values[idx])"
                    idx += 1
                }
                s += "}"
            case is Quantity:
                if idx < values.count {
                    s += jq(field.name) + ":\(values[idx])"
                    idx += 1
                }
            default:
                break
            }
        }
        s += "}"
        return s
    }

    /// Builds a SWE-binary observation body for video.
    ///
    /// Wire format (mirrors BinaryDataWriter.writeBinaryBlock in osh-core):
    ///   [8 bytes] big-endian Double  — Unix wall-clock timestamp
    ///   [4 bytes] big-endian UInt32  — byte length of the compressed frame
    ///   [N bytes] compressed frame   — H264 Annex-B or JPEG bytes
    private func buildBinaryObsBody(timestamp: Double, frame: Data) -> Data {
        var ts  = timestamp.bitPattern.bigEndian
        var len = UInt32(frame.count).bigEndian
        var body = Data(bytes: &ts,  count: 8)
        body.append(Data(bytes: &len, count: 4))
        body.append(frame)
        return body
    }

    // MARK: - Existence checks

    /// Returns true if GET /systems/{id} responds 2xx, false if 404.
    /// Throws on network or other server errors.
    func systemExists(_ id: String) async throws -> Bool {
        let url = baseURL.appendingPathComponent("systems").appendingPathComponent(id)
        return try await resourceExists(url: url)
    }

    /// Returns true if GET /datastreams/{id} responds 2xx, false if 404.
    /// Throws on network or other server errors.
    func datastreamExists(_ id: String) async throws -> Bool {
        let url = baseURL.appendingPathComponent("datastreams").appendingPathComponent(id)
        return try await resourceExists(url: url)
    }

    private func resourceExists(url: URL) async throws -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        if (200...299).contains(http.statusCode) { return true }
        // 404 = gone. 401/3xx = redirect artifact: OSH server redirects 404 errors to its
        // admin error page which requires separate auth and returns 401. Treat all of these
        // as "not registered" — if credentials are genuinely wrong the subsequent POST will
        // also return 401 and surface the real error to the user.
        if http.statusCode == 404 ||
           http.statusCode == 401 ||
           (300...399).contains(http.statusCode) { return false }
        throw ClientError.httpError(http.statusCode)
    }

    // MARK: - HTTP helpers

    private struct PostResponse {
        let statusCode: Int
        let locationId: String?
    }

    private func post(url: URL, body: Data, contentType: String) async throws -> PostResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody   = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ClientError.httpError(http.statusCode)
        }

        // Extract resource id from Location header: e.g. ".../systems/abc123"
        var locationId: String?
        if let location = http.value(forHTTPHeaderField: "Location") {
            locationId = URL(string: location)?.lastPathComponent
        }
        return PostResponse(statusCode: http.statusCode, locationId: locationId)
    }

    @discardableResult
    private func postRaw(url: URL, body: Data, contentType: String) async throws -> Int {
        let result = try await post(url: url, body: body, contentType: contentType)
        return result.statusCode
    }
}

/// MARK: - No-redirect delegate

/// Prevents URLSession from automatically following HTTP redirects.
/// The OSH server redirects 404 responses to its admin error page, which
/// then redirects to /sensorhub and returns 401, masking the real status.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil) // Don't follow; return the original response to the caller.
    }
}

// MARK: - Errors

enum ClientError: Error, LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpError(Int)
    case missingLocation(String)
    case emptyPayload
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL(let s):       return "Invalid URL: \(s)"
        case .invalidResponse:         return "Non-HTTP response received"
        case .httpError(let code):     return "HTTP \(code)"
        case .missingLocation(let s):  return s
        case .emptyPayload:            return "Empty observation payload"
        case .encodingFailed:          return "JSON encoding failed"
        }
    }
}
