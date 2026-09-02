import Foundation

// MARK: - NodeSessionDelegate
//
// The URLSession delegate every connection to one node shares: the two REST
// clients, the command client and the observations WebSocket. It carries the
// two policies that have to agree across all four, because a node reached one
// way and not another is worse than a node that is simply unreachable.
//
// 1. Redirects are never followed. The OSH server redirects a 404 to its admin
//    error page, which redirects to /sensorhub and returns 401 — masking the
//    real status from the caller.
//
// 2. A self-signed certificate is accepted only when the user has said so for
//    this server, and only for that server's own host.
//
// Was NoRedirectDelegate; renamed when trust joined redirects, since the old
// name would have described half of what it does.

final class NodeSessionDelegate: NSObject, URLSessionTaskDelegate {

    /// Host of the configured server URL. A challenge from any other host is
    /// handled normally however the flag is set: the user trusted one server,
    /// not every server a connection might be steered toward.
    private let host: String?

    /// User-set, per server. Off by default and off for every node that has
    /// not been edited since this shipped.
    private let allowSelfSignedCertificates: Bool

    init(host: String?, allowSelfSignedCertificates: Bool) {
        self.host = host
        self.allowSelfSignedCertificates = allowSelfSignedCertificates
    }

    // MARK: Redirects

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil) // Don't follow; return the original response to the caller.
    }

    // MARK: Server trust
    //
    // Session-level rather than task-level on purpose: a server-trust challenge
    // is raised for the connection, and the session-level callback is the one
    // that also fires for a WebSocket task.

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Anything that is not a certificate question — Basic, proxy, client
        // certificates — is none of this delegate's business. The clients send
        // their own Authorization header.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Every condition has to hold. Default handling is the secure path:
        // it is what an untouched install does, and what a mismatched host
        // gets even with the flag on.
        guard allowSelfSignedCertificates,
              let host,
              challenge.protectionSpace.host == host,
              let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        Log.client.info("Accepting user-trusted certificate for \(host, privacy: .public)")
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
