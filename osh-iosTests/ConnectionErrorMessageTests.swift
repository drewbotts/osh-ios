import Testing
import Foundation
@testable import osh_ios

// MARK: - ConnectionErrorMessageTests
//
// The mapping exists so a user is told what to change. These assert on the part
// of the text that carries that instruction, not on whole sentences, so the
// wording can be improved without rewriting the suite.

@Suite("Connection error messages")
struct ConnectionErrorMessageTests {

    @Test("ATS refusal names HTTP as the cause")
    func atsMessage() throws {
        let mapped = try #require(ConnectionErrorMessage.userFacing(
            for: URLError(.appTransportSecurityRequiresSecureConnection)))
        #expect(mapped.suggestion.contains("HTTP"))
    }

    @Test("Certificate failures point at the trust toggle",
          arguments: [URLError.Code.secureConnectionFailed,
                      .serverCertificateUntrusted,
                      .serverCertificateHasUnknownRoot,
                      .serverCertificateHasBadDate,
                      .serverCertificateNotYetValid])
    func certificateMessages(code: URLError.Code) throws {
        let mapped = try #require(ConnectionErrorMessage.userFacing(for: URLError(code)))
        #expect(mapped.title.contains("Certificate"))
        #expect(mapped.suggestion.contains("Trust server certificate"))
    }

    @Test("Timeout, unreachable and offline each map to their own advice")
    func transportMessages() throws {
        let timedOut = try #require(ConnectionErrorMessage.userFacing(for: URLError(.timedOut)))
        #expect(timedOut.title.contains("timed out"))

        let unreachable = try #require(ConnectionErrorMessage.userFacing(for: URLError(.cannotConnectToHost)))
        #expect(unreachable.title.contains("Cannot reach"))

        let offline = try #require(ConnectionErrorMessage.userFacing(for: URLError(.notConnectedToInternet)))
        #expect(offline.title.contains("No network"))
    }

    @Test("An unmapped code defers to the system description")
    func unmappedCodeFallsBack() {
        #expect(ConnectionErrorMessage.userFacing(for: URLError(.badURL)) == nil)

        let error = URLError(.badURL)
        #expect(ConnectionErrorMessage.summary(for: error) == error.localizedDescription)
    }

    @Test("summary joins title and suggestion into one line")
    func summaryIsOneLine() {
        let summary = ConnectionErrorMessage.summary(for: URLError(.serverCertificateUntrusted))
        #expect(summary.contains("Certificate not trusted"))
        #expect(summary.contains("Trust server certificate"))
        #expect(!summary.contains("\n"))
    }

    // The session banner and the connectivity test have to agree, since the
    // whole point of the shared mapper is that the Systems tab, the banner and
    // the log stop phrasing the same failure three ways.
    @MainActor
    @Test("The session banner uses the same mapping")
    func sessionBannerMatches() throws {
        let error = URLError(.serverCertificateUntrusted)
        let mapped = try #require(ConnectionErrorMessage.userFacing(for: error))
        let banner = SensorSession.userFacingMessage(for: error)
        #expect(banner.title == mapped.title)
        #expect(banner.suggestion == mapped.suggestion)
    }
}
