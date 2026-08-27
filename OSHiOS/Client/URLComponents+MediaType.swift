import Foundation

// MARK: - Media types in query strings
//
// Connected Systems passes media types as query values — `?f=application/om+json`,
// `?obsFormat=application/swe+binary` — and the "+" in those subtypes is the
// one character that makes a legal URL mean the wrong thing.
//
// "+" is a legal query character, so URLComponents leaves it alone. A servlet
// container reading the query as application/x-www-form-urlencoded then decodes
// it to a space, and the node sees "application/swe json": OpenSensorHub
// answers 400 for a schema request and 302 for an observations request, the
// latter redirecting to an error page that itself 401s. Neither failure names
// the cause.
//
// Percent-encoding it is what makes the request mean what it says.

extension URLComponents {

    /// Sets `queryItems`, percent-encoding any "+" so it survives the round
    /// trip as a literal plus rather than decoding to a space.
    mutating func setQueryItemsEncodingPlus(_ items: [URLQueryItem]) {
        queryItems = items
        // Applied to the finished query rather than per value: URLComponents
        // has already escaped everything else, and a "+" surviving that escape
        // is by definition a literal one.
        percentEncodedQuery = percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
    }
}
