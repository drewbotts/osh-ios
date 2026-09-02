import Testing
import Foundation
@testable import osh_ios

// MARK: - NodeSessionDelegateTests
//
// The delegate decides whether to accept a certificate that does not chain to a
// trusted root, so the interesting assertions are the refusals: flag off, and
// flag on against a host the user never configured.
//
// A URLAuthenticationChallenge cannot be built with a real SecTrust from a unit
// test — the trust object comes from a live TLS handshake. What is checkable
// without one is the whole decision up to that point, which is where every
// condition of the policy actually lives: a challenge with no serverTrust must
// fall through to default handling no matter how the flag is set, and that is
// also the honest answer for "would this have been accepted". The live remote
// node covers the accept path end to end.

@Suite("Node session delegate")
struct NodeSessionDelegateTests {

    // MARK: Helpers

    private func challenge(host: String,
                           method: String = NSURLAuthenticationMethodServerTrust)
    -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(host: host,
                                       port: 8443,
                                       protocol: "https",
                                       realm: nil,
                                       authenticationMethod: method)
        return URLAuthenticationChallenge(protectionSpace: space,
                                          proposedCredential: nil,
                                          previousFailureCount: 0,
                                          failureResponse: nil,
                                          error: nil,
                                          sender: RecordingSender())
    }

    /// Runs the delegate's trust callback and returns what it decided.
    private func decide(host: String?,
                        allow: Bool,
                        challengeHost: String,
                        method: String = NSURLAuthenticationMethodServerTrust)
    async -> (disposition: URLSession.AuthChallengeDisposition, credential: URLCredential?) {
        let delegate = NodeSessionDelegate(host: host, allowSelfSignedCertificates: allow)
        return await withCheckedContinuation { continuation in
            delegate.urlSession(URLSession.shared,
                                didReceive: challenge(host: challengeHost, method: method)) { disposition, credential in
                continuation.resume(returning: (disposition, credential))
            }
        }
    }

    // MARK: Refusals

    @Test("Flag off falls through to default handling")
    func flagOffUsesDefaultHandling() async {
        let (disposition, credential) = await decide(host: "192.168.4.34",
                                                     allow: false,
                                                     challengeHost: "192.168.4.34")
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    @Test("Flag on but a different host falls through to default handling")
    func hostMismatchUsesDefaultHandling() async {
        let (disposition, credential) = await decide(host: "192.168.4.34",
                                                     allow: true,
                                                     challengeHost: "evil.example.com")
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    @Test("Flag on with no configured host never accepts")
    func nilHostUsesDefaultHandling() async {
        let (disposition, credential) = await decide(host: nil,
                                                     allow: true,
                                                     challengeHost: "192.168.4.34")
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    @Test("A matching host is compared exactly, not by suffix")
    func suffixHostIsNotAMatch() async {
        // "4.34.evil.com" ends with nothing in common, but a sloppier check
        // using hasSuffix on the configured host would match "x192.168.4.34".
        let (disposition, _) = await decide(host: "192.168.4.34",
                                            allow: true,
                                            challengeHost: "x192.168.4.34")
        #expect(disposition == .performDefaultHandling)
    }

    // MARK: Non-certificate challenges

    @Test("A Basic auth challenge is left to default handling either way",
          arguments: [true, false])
    func basicAuthIsNotTouched(allow: Bool) async {
        let (disposition, credential) = await decide(host: "192.168.4.34",
                                                     allow: allow,
                                                     challengeHost: "192.168.4.34",
                                                     method: NSURLAuthenticationMethodHTTPBasic)
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    // MARK: Matching host, flag on
    //
    // No SecTrust is reachable from here, so this documents the boundary: the
    // policy's own conditions have all passed and only the trust object is
    // missing, which must still not produce a credential.

    @Test("Matching host with no trust object yields no credential")
    func matchingHostWithoutTrustYieldsNoCredential() async {
        let (disposition, credential) = await decide(host: "192.168.4.34",
                                                     allow: true,
                                                     challengeHost: "192.168.4.34")
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    // MARK: Redirects

    @Test("Redirects are never followed")
    func redirectsAreSuppressed() async {
        let delegate = NodeSessionDelegate(host: "192.168.4.34",
                                           allowSelfSignedCertificates: false)
        let url = URL(string: "http://192.168.4.34:8080/sensorhub/api/systems")!
        let response = HTTPURLResponse(url: url,
                                       statusCode: 302,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": "https://192.168.4.34:8443/sensorhub/api/systems"])!
        let followed: URLRequest? = await withCheckedContinuation { continuation in
            delegate.urlSession(URLSession.shared,
                                task: URLSession.shared.dataTask(with: url),
                                willPerformHTTPRedirection: response,
                                newRequest: URLRequest(url: url)) { request in
                continuation.resume(returning: request)
            }
        }
        #expect(followed == nil)
    }
}

// MARK: - RecordingSender

/// URLAuthenticationChallenge requires a sender. The delegate answers through
/// its completion handler and never calls the sender, so these are unreachable
/// in practice — but the protocol has to be satisfied to build a challenge.
private final class RecordingSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
