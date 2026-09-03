@testable import MetadataAPI
import Testing

/// `MetadataError` had no `LocalizedError` conformance, so `error.localizedDescription`
/// in the wizard (`MetadataWizardModel.search`/`selectEpisode`/etc.) fell back to
/// Foundation's generic "The operation couldn't be completed" bridging text —
/// silently dropping the whole point of `.missingAPIKey`'s doc comment: a
/// first-time user with no TMDB key set gets an unreadable error instead of
/// being told to add one in Preferences.
@Suite("MetadataError descriptions")
struct MetadataErrorTests {
    @Test func missingAPIKeyNamesTheProviderAndWhereToFixIt() throws {
        let message = MetadataError.missingAPIKey(provider: "TMDB").errorDescription
        #expect(message != nil)
        #expect(try #require(message?.contains("TMDB")))
        #expect(try #require(message?.localizedCaseInsensitiveContains("Preferences")))
    }

    @Test func everyCaseHasAReadableDescription() {
        let cases: [MetadataError] = [
            .emptyQuery,
            .server(status: 401, message: "Invalid API key"),
            .server(status: 500, message: nil),
            .notAvailable(region: "Germany"),
            .malformedResponse("no results field"),
            .transport("offline"),
            .missingAPIKey(provider: "TMDB")
        ]
        for error in cases {
            #expect(!(error.errorDescription ?? "").isEmpty)
        }
    }

    @Test func serverErrorPrefersTMDBsOwnMessage() throws {
        let message = MetadataError.server(status: 401, message: "Invalid API key: xyz").errorDescription
        #expect(try #require(message?.contains("Invalid API key: xyz")))
    }
}
