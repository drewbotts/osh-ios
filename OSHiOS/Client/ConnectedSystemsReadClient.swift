import Foundation
import CoreLocation

// MARK: - ConnectedSystemsReadClient
//
// The read half of the Connected Systems API. ConnectedSystemsClient owns
// everything this app *writes* — its ordered-string JSON builders exist because
// the node's streaming parser is order-sensitive, and nothing here may disturb
// that. Reading has the opposite shape: ordinary Codable decoding, no schema
// building, no observation posting. Keeping the two apart means the browse and
// viewer features can grow without touching the code that feeds the node.
//
// Endpoints used:
//   GET /systems?limit=N                      → collection of systems
//   GET /systems/{id}                         → one system
//   GET /systems/{id}/datastreams             → collection of datastreams
//   GET /datastreams/{id}                     → one datastream
//   GET /datastreams/{id}/schema?obsFormat=…  → raw SWE schema document

actor ConnectedSystemsReadClient {

    private let baseURL: URL
    private let authHeader: String
    private let session: URLSession

    // MARK: Init

    /// Same signature and auth/redirect handling as ConnectedSystemsClient, so
    /// a NodeConnection can build both from one ServerConfig.
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
        self.session = URLSession(configuration: config,
                                  delegate: NoRedirectDelegate(),
                                  delegateQueue: nil)
    }

    // MARK: Systems

    func listSystems(limit: Int = 100) async throws -> [SystemSummary] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("systems"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        guard let url = components?.url else { throw ClientError.invalidURL("systems?limit=\(limit)") }

        let data = try await get(url: url)
        let response: ItemsResponse<SystemSummary> = try decode(data, from: url)
        return response.items
    }

    func getSystem(id: String) async throws -> SystemSummary {
        let url = baseURL.appendingPathComponent("systems").appendingPathComponent(id)
        let data = try await get(url: url)
        return try decode(data, from: url)
    }

    // MARK: Datastreams

    func listDatastreams(systemId: String) async throws -> [DatastreamSummary] {
        let url = baseURL
            .appendingPathComponent("systems")
            .appendingPathComponent(systemId)
            .appendingPathComponent("datastreams")
        let data = try await get(url: url)
        let response: ItemsResponse<DatastreamSummary> = try decode(data, from: url)
        return response.items
    }

    func getDatastream(id: String) async throws -> DatastreamSummary {
        let url = baseURL.appendingPathComponent("datastreams").appendingPathComponent(id)
        let data = try await get(url: url)
        return try decode(data, from: url)
    }

    /// GET /datastreams/{id}/schema?obsFormat=<mime> — returned verbatim.
    ///
    /// Deliberately undecoded: a SWE schema document is far richer than the
    /// DataRecord model this app builds for its own outputs, and a lossy decode
    /// would quietly discard the parts a viewer will eventually need. A later
    /// pass adds real SWE decoding; until then the caller gets the bytes.
    func getDatastreamSchemaJSON(id: String, obsFormat: String) async throws -> Data {
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("datastreams")
                .appendingPathComponent(id)
                .appendingPathComponent("schema"),
            resolvingAgainstBaseURL: false)
        components?.setQueryItemsEncodingPlus([URLQueryItem(name: "obsFormat", value: obsFormat)])
        guard let url = components?.url else {
            throw ClientError.invalidURL("datastreams/\(id)/schema")
        }
        return try await get(url: url, accept: obsFormat)
    }

    // MARK: Schemas and decoders

    /// Both schema representations of one datastream.
    ///
    /// swe+json is required; swe+binary is attempted and comes back nil when
    /// the node does not serve it. Those are different situations and the
    /// caller needs to tell them apart: a stream with no binary schema is a
    /// plain scalar stream, while a stream with no *json* schema is a video
    /// one, and the reference node answers 400 for exactly that case.
    func getDatastreamSchema(id: String) async throws
        -> (json: SWESchemaDecoder.DatastreamSchema, binary: SWESchemaDecoder.DatastreamSchema?) {

        async let jsonData = getDatastreamSchemaJSON(id: id, obsFormat: Self.sweJSON)
        let binaryData = try? await getDatastreamSchemaJSON(id: id, obsFormat: Self.sweBinary)

        let json = try SWESchemaDecoder.decode(try await jsonData)

        guard let binaryData else {
            Log.client.debug("Datastream \(id, privacy: .public) serves no \(Self.sweBinary, privacy: .public) schema")
            return (json, nil)
        }
        return (json, try? SWESchemaDecoder.decode(binaryData))
    }

    /// Builds a decoder for one datastream.
    ///
    /// The binary schema is preferred when there is one: it carries the same
    /// recordSchema plus the recordEncoding, so it can decode both formats
    /// while the json schema can only decode json.
    func makeDecoder(datastreamId: String) async throws -> DatastreamDecoder {
        // A video datastream has no swe+json schema at all, so falling back to
        // the binary one is the only way to build a decoder for it.
        if let binaryData = try? await getDatastreamSchemaJSON(id: datastreamId,
                                                              obsFormat: Self.sweBinary),
           let binary = try? SWESchemaDecoder.decode(binaryData) {
            return try DatastreamDecoder(datastreamId: datastreamId, schema: binary)
        }

        let jsonData = try await getDatastreamSchemaJSON(id: datastreamId, obsFormat: Self.sweJSON)
        return try DatastreamDecoder(datastreamId: datastreamId,
                                     schema: try SWESchemaDecoder.decode(jsonData))
    }

    // MARK: Observations

    /// One page of observations, decoded.
    ///
    /// - Returns: the page's observations and the URL of the next page, when
    ///   the node offers one. Paging is by link rather than by offset because
    ///   that is what the node's `links` array expresses, and recomputing an
    ///   offset would skip or repeat records on a stream still being written.
    /// - Parameter latest: ask the node for the most recent observations
    ///   instead of the oldest. The default ordering is ascending by
    ///   phenomenonTime, so a plain `limit: 10` on an archive returns the ten
    ///   oldest records — almost never what a caller showing "recent activity"
    ///   means. Ignored when `phenomenonTime` is given.
    func fetchObservations(datastreamId: String,
                           phenomenonTime: ClosedRange<Date>? = nil,
                           latest: Bool = false,
                           limit: Int = 100,
                           format: String = "application/om+json",
                           decoder: DatastreamDecoder) async throws
        -> (observations: [ParsedObservation], nextURL: URL?) {

        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("datastreams")
                .appendingPathComponent(datastreamId)
                .appendingPathComponent("observations"),
            resolvingAgainstBaseURL: false)

        var query = [URLQueryItem(name: "f", value: format),
                     URLQueryItem(name: "limit", value: String(limit))]
        if let phenomenonTime {
            query.append(URLQueryItem(
                name: "phenomenonTime",
                value: "\(Self.iso(phenomenonTime.lowerBound))/\(Self.iso(phenomenonTime.upperBound))"))
        } else if latest {
            query.append(URLQueryItem(name: "phenomenonTime", value: "latest"))
        }
        components?.setQueryItemsEncodingPlus(query)

        guard let url = components?.url else {
            throw ClientError.invalidURL("datastreams/\(datastreamId)/observations")
        }
        return try await fetchObservations(url: url, format: format, decoder: decoder)
    }

    /// Fetches one page by URL — used to follow a `next` link.
    func fetchObservations(url: URL,
                           format: String = "application/om+json",
                           decoder: DatastreamDecoder) async throws
        -> (observations: [ParsedObservation], nextURL: URL?) {

        let data = try await get(url: url, accept: format)

        let observations: [ParsedObservation]
        if format.localizedCaseInsensitiveContains("binary") {
            observations = try decoder.decode(binary: data)
        } else {
            observations = try decoder.decode(json: data)
        }
        return (observations, Self.nextLink(in: data, relativeTo: url))
    }

    /// The `rel: "next"` link in a collection response, if any.
    ///
    /// Only meaningful for the JSON collection formats; a swe+json page is a
    /// bare array and a binary page is bytes, neither of which carries links.
    private static func nextLink(in data: Data, relativeTo url: URL) -> URL? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let links = root["links"] as? [Any] else { return nil }

        for entry in links {
            guard let link = entry as? [String: Any],
                  (link["rel"] as? String) == "next",
                  let href = link["href"] as? String else { continue }
            return URL(string: href, relativeTo: url)?.absoluteURL
        }
        return nil
    }

    // MARK: Subsystems

    /// Child systems of one system.
    ///
    /// A node that models no hierarchy answers 404 rather than an empty
    /// collection, and "this system has no subsystems" is the right reading of
    /// that — not an error worth failing a browse over.
    func listSubsystems(systemId: String) async throws -> [SystemSummary] {
        let url = baseURL
            .appendingPathComponent("systems")
            .appendingPathComponent(systemId)
            .appendingPathComponent("subsystems")
        do {
            let data = try await get(url: url)
            let response: ItemsResponse<SystemSummary> = try decode(data, from: url)
            return response.items
        } catch ClientError.httpError(404) {
            return []
        }
    }

    // MARK: Location

    /// Where a system is, when it says.
    ///
    /// Tried on the system's own geometry first and its sampling features
    /// second. Every failure yields nil rather than throwing: a system without
    /// a location is ordinary, and a map that cannot plot one pin should still
    /// draw the rest.
    func getSystemLocation(systemId: String) async throws -> CLLocationCoordinate2D? {
        let systemURL = baseURL
            .appendingPathComponent("systems")
            .appendingPathComponent(systemId)

        if let data = try? await get(url: systemURL, accept: "application/geo+json"),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let point = Self.point(in: root["geometry"]) {
            return point
        }

        let featuresURL = systemURL.appendingPathComponent("samplingFeatures")
        guard let data = try? await get(url: featuresURL, accept: "application/geo+json"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [Any] else { return nil }

        for item in items {
            guard let feature = item as? [String: Any] else { continue }
            if let point = Self.point(in: feature["geometry"]) { return point }
        }
        return nil
    }

    /// A GeoJSON Point's coordinates, which are [lon, lat] — the opposite
    /// order from CLLocationCoordinate2D's initialiser.
    private static func point(in geometry: Any?) -> CLLocationCoordinate2D? {
        guard let object = geometry as? [String: Any],
              (object["type"] as? String) == "Point",
              let coordinates = object["coordinates"] as? [Any],
              coordinates.count >= 2,
              let longitude = (coordinates[0] as? NSNumber)?.doubleValue,
              let latitude = (coordinates[1] as? NSNumber)?.doubleValue else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    // MARK: Format constants

    static let sweJSON = "application/swe+json"
    static let sweBinary = "application/swe+binary"
    static let omJSON = "application/om+json"

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    // MARK: HTTP

    private func get(url: URL, accept: String = "application/json") async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            Log.client.error("GET \(url.path, privacy: .public) → HTTP \(http.statusCode)")
            throw ClientError.httpError(http.statusCode)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data, from url: URL) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // The body is what makes an unexpected shape diagnosable; the models
            // are tolerant enough that reaching here means something structural.
            let body = String(data: data.prefix(4096), encoding: .utf8) ?? "<non-UTF8 body>"
            Log.client.debug("Decode failed for \(url.path, privacy: .public): \(body, privacy: .public)")
            throw error
        }
    }
}
