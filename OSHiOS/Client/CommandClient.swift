import Foundation

// MARK: - CommandClient
//
// The write half of commanding: POST /controlstreams/{id}/commands.
//
// Every byte of the request body is built as an ordered string rather than by
// JSONEncoder, exactly as ConnectedSystemsClient builds observations. The reason
// is the same: the node parses these with a streaming reader that walks the
// document in the order the schema declares, and a Swift Dictionary has no
// order at all. `ptzPos` is the case that proves it — send its three fields in
// any order but pan, tilt, zoom and the node answers
//
//     Invalid payload: Invalid JSON: Expected a name but was END_OBJECT
//         at line 1 column 36 path $.parameters.ptzPos.pan
//
// which is the parser saying it wanted the next declared field and got the end
// of the object. See COMMANDS.md for the whole verified exchange.
//
// The envelope below was determined empirically against the reference node, not
// from a specification: the node's OpenAPI document is not served at any path
// this client could reach.

actor CommandClient {

    private let baseURL: URL
    /// nil for an anonymous node — see BasicAuth.
    private let authHeader: String?
    private let session: URLSession

    // MARK: Init

    /// Same signature and auth/redirect handling as the other two clients, so a
    /// NodeConnection can build all three from one ServerConfig.
    init(nodeURL: String, username: String, password: String) throws {
        guard let url = URL(string: nodeURL.hasSuffix("/") ? nodeURL : nodeURL + "/") else {
            throw ClientError.invalidURL(nodeURL)
        }
        self.baseURL = url
        self.authHeader = BasicAuth.header(username: username, password: password)

        let config = URLSessionConfiguration.default
        // Shorter than the read client's. A command is a button press: if the
        // camera has not answered in ten seconds the user has already pressed
        // it again, and a queue of stale moves is worse than a failure.
        config.timeoutIntervalForRequest  = 10
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config,
                                  delegate: NoRedirectDelegate(),
                                  delegateQueue: nil)
    }

    // MARK: Receipt

    struct CommandReceipt: Sendable {
        /// The node's `command@id`, when it returned one.
        let id: String?
        let statusCode: Int
        let body: Data

        var isSuccess: Bool { (200...299).contains(statusCode) }
        /// True for the two statuses that mean "you may not do this", which the
        /// UI treats differently from a command the camera refused.
        var isUnauthorized: Bool { statusCode == 401 || statusCode == 403 }

        /// `statusCode` from the node's own status report, e.g. "COMPLETED".
        var reportedStatus: String? { Self.string(inBody: body, key: "statusCode") }
        /// The node's error text on a 4xx, which names the offending path.
        var message: String? { Self.string(inBody: body, key: "message") }

        var bodyText: String {
            String(data: body.prefix(4096), encoding: .utf8) ?? "<non-UTF8 body>"
        }

        private static func string(inBody data: Data, key: String) -> String? {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return root[key] as? String
        }
    }

    // MARK: Sending

    /// Issues one command.
    ///
    /// - Parameter json: the full request body, from `CommandBody`.
    /// - Returns: a receipt for *any* HTTP response, success or not. A refused
    ///   command is information the controller has to show — the status and the
    ///   node's message are how a user learns their credentials are read-only —
    ///   so only a transport failure throws.
    func sendCommand(controlStreamId: String, parameters json: String) async throws
        -> CommandReceipt {

        let url = baseURL
            .appendingPathComponent("controlstreams")
            .appendingPathComponent(controlStreamId)
            .appendingPathComponent("commands")

        guard let body = json.data(using: .utf8) else { throw ClientError.encodingFailed }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Without an explicit Accept the node serves its HTML admin console for
        // some paths, which then demands a login even where the API does not.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authHeader { request.setValue(authHeader, forHTTPHeaderField: "Authorization") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }

        let receipt = CommandReceipt(id: Self.commandId(in: data),
                                     statusCode: http.statusCode,
                                     body: data)

        if receipt.isSuccess {
            Log.client.info("Command on \(controlStreamId, privacy: .public) → \(http.statusCode) \(receipt.reportedStatus ?? "-", privacy: .public) id \(receipt.id ?? "-", privacy: .public)")
        } else {
            Log.client.error("Command on \(controlStreamId, privacy: .public) → HTTP \(http.statusCode): \(receipt.bodyText, privacy: .public)")
        }
        return receipt
    }

    /// Best-effort status of a command already issued; nil when unknown.
    ///
    /// Implemented as a listing and a match rather than a GET on the command.
    /// The reference node has no `/controlstreams/{id}/commands/{commandId}`
    /// resource — it answers 404, and the top-level `/commands/{id}` answers
    /// 400 "Invalid resource name" — so the collection is the only place a
    /// status lives.
    func getCommandStatus(controlStreamId: String, commandId: String) async throws -> String? {
        let url = baseURL
            .appendingPathComponent("controlstreams")
            .appendingPathComponent(controlStreamId)
            .appendingPathComponent("commands")

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: "20")]
        guard let listURL = components?.url else { return nil }

        var request = URLRequest(url: listURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authHeader { request.setValue(authHeader, forHTTPHeaderField: "Authorization") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode != 404 else { return nil }
        guard (200...299).contains(http.statusCode) else { return nil }

        let commands = try JSONDecoder().decode(ItemsResponse<CommandSummary>.self, from: data)
        return commands.items.first { $0.id == commandId }?.currentStatus
    }

    /// The `command@id` in a status report body.
    private static func commandId(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (root["command@id"] as? String) ?? (root["id"] as? String)
    }
}
