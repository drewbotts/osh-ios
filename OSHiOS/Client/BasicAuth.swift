import Foundation

// MARK: - BasicAuth
//
// Whether to send credentials at all.
//
// Plenty of OSH deployments are open: a demo node, a node behind a VPN, a node
// on a boat's own network. Sending "Basic OjE=" — an empty username with an
// empty password — to one of those is not neutral. A node with security
// enabled but anonymous read allowed will try to authenticate the empty user,
// fail, and answer 401 for a resource it would have served happily to a request
// with no Authorization header at all.
//
// So an empty username means no header, everywhere: the read client, the write
// client and the WebSocket handshake. One place decides, because a viewer that
// could browse but not stream would be a maddening bug.

enum BasicAuth {

    /// The `Authorization` value for a server, or nil when it is anonymous.
    static func header(username: String, password: String) -> String? {
        let user = username.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { return nil }
        let credentials = Data("\(user):\(password)".utf8).base64EncodedString()
        return "Basic \(credentials)"
    }
}
