import Foundation

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
        components?.queryItems = [URLQueryItem(name: "obsFormat", value: obsFormat)]
        guard let url = components?.url else {
            throw ClientError.invalidURL("datastreams/\(id)/schema")
        }
        return try await get(url: url, accept: obsFormat)
    }

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
