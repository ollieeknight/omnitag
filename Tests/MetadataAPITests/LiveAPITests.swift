import Foundation
import Testing
@testable import MetadataAPI

/// Opt-in checks against the real APIs: `OMNITAG_LIVE=1 make test`. Off by
/// default so the suite stays offline, but these are what caught every wrong
/// assumption about how Audible's search actually behaves.
@Suite("Live APIs", .enabled(if: ProcessInfo.processInfo.environment["OMNITAG_LIVE"] != nil), .serialized)
struct LiveAPITests {
    @Test("an ASIN resolves to the exact book, with chapters and artwork")
    func asinLookup() async throws {
        let service = AudiobookMetadataService(region: .unitedKingdom)
        let outcome = try await service.searchWithRegion(.init(asin: "B01M11U23O"))
        let candidate = try #require(outcome.candidates.first)

        #expect(candidate.title.contains("Secret Diary of Laura Palmer"))
        #expect(candidate.authors == ["Jennifer Lynch"])

        let details = try await service.details(for: candidate.asin, in: outcome.region)
        #expect(details.book.narrators == ["Sheryl Lee"])
        #expect(details.chapters.count > 80)
        #expect(details.book.artworkURL != nil)
    }

    @Test("a UK-first search falls back to the US storefront for a US-only book")
    func regionFallbackIsReal() async throws {
        let service = AudiobookMetadataService(region: .unitedKingdom)
        let outcome = try await service.searchWithRegion(.init(asin: "B01M11U23O"))
        #expect(outcome.region == .unitedStates, "this title is not sold in the UK")
    }

    @Test("keyword search finds books that are in the index")
    func keywordSearch() async throws {
        let service = AudiobookMetadataService(region: .unitedKingdom)
        let outcome = try await service.searchWithRegion(.init(title: "The Secret History of Twin Peaks"))
        #expect(outcome.candidates.contains { $0.authors.contains("Mark Frost") })
    }

    /// Audible's public keyword index does not contain every book it sells:
    /// The Secret Diary of Laura Palmer is reachable by ASIN and invisible to
    /// search, in every phrasing tried. This is why the wizard takes an ASIN or
    /// a pasted Audible URL as a first-class input rather than only free text.
    @Test("some books exist only by ASIN, never in search results")
    func searchIndexHasHoles() async throws {
        let service = AudiobookMetadataService(region: .unitedStates)
        let outcome = try await service.searchWithRegion(.init(keywords: "secret diary laura palmer"))
        #expect(outcome.candidates.contains { $0.asin == "B01M11U23O" } == false,
                "if this now passes, Audible indexed the book and the note above can go")
    }
}
