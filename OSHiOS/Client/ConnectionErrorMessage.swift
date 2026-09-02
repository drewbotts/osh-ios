import Foundation

// MARK: - ConnectionErrorMessage
//
// One place where a transport failure becomes words a user can act on.
//
// The connectivity test and the session's error banner used to phrase these
// independently, and the test simply passed URLError.localizedDescription
// through — "The resource could not be loaded because the App Transport
// Security policy requires the use of a secure connection", or worse, the bare
// "could not connect to the server". Neither names the fix.
//
// The two failures a field user actually hits are a node speaking plain HTTP
// and a node with a self-signed certificate, so those get specific advice that
// points at the setting which resolves them. Everything else falls through to
// the system's own description, which is accurate even when it is terse.

enum ConnectionErrorMessage {

    /// Advice for a URLError, or nil when the system's own description says it
    /// at least as well.
    static func userFacing(for error: URLError) -> (title: String, suggestion: String)? {
        switch error.code {

        case .appTransportSecurityRequiresSecureConnection:
            return ("Blocked by App Transport Security",
                    "This server uses HTTP, which iOS blocks by default. Use an https:// URL, or a build that permits plain HTTP.")

        // A self-signed certificate lands on .serverCertificateUntrusted; the
        // others in this family are the same problem seen from a different
        // angle (unknown root, wrong dates), and the same toggle answers them.
        case .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateHasBadDate,
             .serverCertificateNotYetValid:
            return ("Certificate not trusted",
                    "Enable \"Trust server certificate (self-signed)\" for this server if it is yours.")

        case .timedOut:
            return ("Connection timed out",
                    "The server took too long to respond — check the URL and try again.")

        case .cannotConnectToHost, .cannotFindHost:
            return ("Cannot reach server",
                    "Check the server URL and make sure the OSH node is running.")

        case .notConnectedToInternet, .networkConnectionLost:
            return ("No network connection",
                    "Check your network connection and try again.")

        default:
            return nil
        }
    }

    /// A single line for the places that show one string — the Systems tab
    /// status row, the connectivity result, the log. Falls back to the system
    /// description so no error is ever reported as an empty message.
    static func summary(for error: Error) -> String {
        guard let urlError = error as? URLError,
              let (title, suggestion) = userFacing(for: urlError)
        else { return error.localizedDescription }
        return "\(title) — \(suggestion)"
    }
}
