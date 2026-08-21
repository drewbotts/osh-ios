import Foundation

// MARK: - NoRedirectDelegate

/// Prevents URLSession from automatically following HTTP redirects.
///
/// The OSH server redirects 404 responses to its admin error page, which then
/// redirects to /sensorhub and returns 401 — masking the real status code from
/// the caller. Both the write client (ConnectedSystemsClient) and the read
/// client (ConnectedSystemsReadClient) talk to the same node and need the same
/// behaviour, which is why this lives on its own rather than inside either.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
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
