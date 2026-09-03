import Foundation
import MediaCore
@testable import MetadataAPI
import Testing

/// Serves recorded API responses, so the suite is offline and deterministic.
/// Recorded from the live APIs on 2026-08-31; re-record with `make fixtures`.
class StubTransport: HTTPTransporting, @unchecked Sendable {
    private(set) var requestedURLs: [URL] = []
    var responses: [String: Data] = [:]
    var status = 200

    func data(from url: URL) async throws -> (Data, Int) {
        requestedURLs.append(url)
        // Longest key first: a chapters URL contains "books/" too, and a
        // dictionary's order would otherwise decide which fixture answers.
        let match = responses
            .sorted { $0.key.count > $1.key.count }
            .first { url.absoluteString.contains($0.key) }
        guard let match else { return (Data("{}".utf8), 404) }
        return (match.value, status)
    }

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}

@Suite("AudibleClient")
struct AudibleClientTests {
    private func client(_ region: AudibleRegion = .unitedKingdom) throws -> (AudibleClient, StubTransport) {
        let transport = StubTransport()
        transport.responses["catalog/products?"] = try StubTransport.fixture("audible-search")
        return (AudibleClient(region: region, transport: transport), transport)
    }

    @Test("searches the regional domain the user chose")
    func usesRegionalHost() async throws {
        let (client, transport) = try client(.unitedKingdom)
        _ = try await client.search(.init(keywords: "twin peaks"))
        #expect(transport.requestedURLs.first?.host == "api.audible.co.uk")

        let (us, usTransport) = try self.client(.unitedStates)
        _ = try await us.search(.init(keywords: "twin peaks"))
        #expect(usTransport.requestedURLs.first?.host == "api.audible.com")
    }

    @Test("turns a keyword search into candidates")
    func parsesSearchResults() async throws {
        let (client, _) = try client()
        let results = try await client.search(.init(keywords: "twin peaks laura palmer"))

        #expect(results.count > 1)
        let secretHistory = try #require(results.first { $0.title.contains("Secret History") })
        #expect(secretHistory.id == "B01M62H4JK")
        #expect(secretHistory.authors == ["Mark Frost"])
        #expect(secretHistory.artworkURL != nil)
    }

    @Test("searches on the title alone — everything else is only ever keywords")
    func structuredSearchBecomesKeywords() async throws {
        let (client, transport) = try client()
        _ = try await client.search(.init(title: "Secret Diary", author: "Jennifer Lynch"))

        let query = try #require(transport.requestedURLs.first?.query)
        #expect(query.contains("keywords=Secret%20Diary") || query.contains("keywords=Secret+Diary"))
        // Verified live: title= returns nothing, author= matches unrelated books,
        // and an author inside the keywords drops the result count to zero.
        #expect(query.contains("title=") == false)
        #expect(query.contains("author=") == false)
        #expect(query.contains("Lynch") == false, "the author ranks results, it does not narrow them")
    }

    @Test("an ASIN goes to the by-ASIN endpoint, not the search index")
    func asinUsesProductEndpoint() async throws {
        let transport = StubTransport()
        transport.responses["catalog/products/B01M11U23O"] = Data(#"{"product":{"asin":"B01M11U23O","title":"The Secret Diary of Laura Palmer"}}"#.utf8)
        let client = AudibleClient(region: .unitedStates, transport: transport)

        let results = try await client.search(.init(asin: "B01M11U23O"))
        #expect(results.count == 1)
        #expect(results[0].title == "The Secret Diary of Laura Palmer")
        #expect(transport.requestedURLs.first?.path == "/1.0/catalog/products/B01M11U23O")
    }

    @Test("an empty query is refused before it reaches the network")
    func refusesEmptyQuery() async throws {
        let (client, transport) = try client()
        await #expect(throws: MetadataError.self) { try await client.search(.init()) }
        #expect(transport.requestedURLs.isEmpty)
    }

    @Test("reports a server error rather than returning nothing")
    func surfacesServerErrors() async throws {
        let (client, transport) = try client()
        transport.status = 503
        await #expect(throws: MetadataError.self) { try await client.search(.init(keywords: "x")) }
    }
}

@Suite("AudnexusClient")
struct AudnexusClientTests {
    private func client(_ region: AudibleRegion = .unitedKingdom) throws -> (AudnexusClient, StubTransport) {
        let transport = StubTransport()
        transport.responses["/chapters"] = try StubTransport.fixture("audnexus-chapters")
        transport.responses["books/"] = try StubTransport.fixture("audnexus-book")
        return (AudnexusClient(region: region, transport: transport), transport)
    }

    @Test("maps a book onto the tag keys OmniTag already understands")
    func mapsBookToTags() async throws {
        let (client, _) = try client()
        let book = try await client.book(asin: "B01M11U23O")

        #expect(book.title == "The Secret Diary of Laura Palmer (Twin Peaks)")
        #expect(book.authors == ["Jennifer Lynch"])
        #expect(book.narrators == ["Sheryl Lee"])
        #expect(book.publisher == "Audible Studios")
        #expect(book.year == 2017)
        #expect(book.id == "B01M11U23O")
        #expect(book.artworkURL?.absoluteString.hasSuffix(".jpg") == true)

        let tags = book.tagSet
        #expect(tags.title == "The Secret Diary of Laura Palmer (Twin Peaks)")
        #expect(tags[.author] == .string("Jennifer Lynch"))
        #expect(tags[.narrator] == .string("Sheryl Lee"))
        #expect(tags[.asin] == .string("B01M11U23O"))
        #expect(tags[.year] == .number(2017))
    }

    @Test("keeps only the genre rungs, not every tag Audible hangs off them")
    func mapsGenres() async throws {
        let (client, _) = try client()
        let book = try await client.book(asin: "B01M11U23O")
        #expect(book.genres == ["Literature & Fiction", "Mystery, Thriller & Suspense"])
    }

    @Test("reads chapters with their start times")
    func readsChapters() async throws {
        let (client, _) = try client()
        let chapters = try await client.chapters(asin: "B01M11U23O")

        #expect(chapters.count == 6)
        #expect(chapters[0].start == 0)
        #expect(chapters[0].title == "Chapter 1")
        #expect(chapters[1].start == 209.537, "start offsets are milliseconds in the API")
        #expect(chapters[1].index == 1)
    }

    @Test("passes the region through, because a book can be US-only")
    func passesRegion() async throws {
        let (client, transport) = try client(.unitedKingdom)
        _ = try? await client.book(asin: "B01M11U23O")
        #expect(transport.requestedURLs.first?.query?.contains("region=uk") == true)
    }

    @Test("a region-unavailable answer is a clear error, not an empty book")
    func regionUnavailable() async throws {
        let (client, transport) = try client()
        transport.responses = ["books/": Data(#"{"error":{"code":"REGION_UNAVAILABLE"}}"#.utf8)]
        await #expect(throws: MetadataError.self) { try await client.book(asin: "B01M11U23O") }
    }
}

/// Answers differently per storefront, so region fallback can be tested.
final class RegionalStubTransport: StubTransport, @unchecked Sendable {
    var emptyHosts: Set<String> = []
    /// Keyword values that should come back with no products.
    var emptyKeywords: Set<String> = []
    /// Query fragment → the error body that region should return.
    var regionalErrors: [String: Data] = [:]

    override func data(from url: URL) async throws -> (Data, Int) {
        let (data, status) = try await super.data(from: url)
        if let host = url.host, emptyHosts.contains(host) {
            return (Data(#"{"products":[]}"#.utf8), 200)
        }
        let keywords = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "keywords" }?.value
        if let keywords, emptyKeywords.contains(keywords) {
            return (Data(#"{"products":[]}"#.utf8), 200)
        }
        if let match = regionalErrors.first(where: { url.query?.contains($0.key) == true }) {
            return (match.value, 200)
        }
        return (data, status)
    }
}

@Suite("AudibleProvider")
struct AudibleProviderTests {
    private func service() throws -> (AudibleProvider, StubTransport) {
        let transport = StubTransport()
        transport.responses["catalog/products?"] = try StubTransport.fixture("audible-search")
        transport.responses["/chapters"] = try StubTransport.fixture("audnexus-chapters")
        transport.responses["books/"] = try StubTransport.fixture("audnexus-book")
        return (AudibleProvider(region: .unitedKingdom, transport: transport), transport)
    }

    @Test("searches Audible and enriches the chosen result from Audnexus")
    func searchThenDetails() async throws {
        let (service, _) = try service()
        let results = try await service.search(.init(keywords: "twin peaks"))
        let details = try await service.details(for: #require(results.first).id)

        #expect(details.book.narrators == ["Sheryl Lee"])
        #expect(details.chapters.count == 6)
    }

    @Test("a missing chapter list is not a failure — the book still comes back")
    func chaptersAreOptional() async throws {
        let (service, transport) = try service()
        transport.responses.removeValue(forKey: "/chapters")
        let details = try await service.details(for: "B01M11U23O")

        #expect(details.book.title.isEmpty == false)
        #expect(details.chapters.isEmpty)
    }

    @Test("falls back to the US storefront when the chosen region has nothing")
    func regionFallback() async throws {
        let transport = RegionalStubTransport()
        transport.emptyHosts = ["api.audible.co.uk"]
        transport.responses["catalog/products?"] = try StubTransport.fixture("audible-search")
        let service = AudibleProvider(region: .unitedKingdom, transport: transport)

        let outcome = try await service.searchWithRegion(.init(keywords: "laura palmer"))
        #expect(outcome.region == .unitedStates, "the UK storefront does not stock every book")
        #expect(outcome.candidates.isEmpty == false)
        #expect(transport.requestedURLs.map(\.host) == ["api.audible.co.uk", "api.audible.com"])
    }

    @Test("details fall back to the US when a book is not sold in the region")
    func detailsRegionFallback() async throws {
        let transport = RegionalStubTransport()
        transport.regionalErrors = ["region=uk": Data(#"{"error":{"code":"REGION_UNAVAILABLE"}}"#.utf8)]
        transport.responses["/chapters"] = try StubTransport.fixture("audnexus-chapters")
        transport.responses["books/"] = try StubTransport.fixture("audnexus-book")
        let service = AudibleProvider(region: .unitedKingdom, transport: transport)

        let details = try await service.details(for: "B01M11U23O")
        #expect(details.book.narrators == ["Sheryl Lee"])
        #expect(transport.requestedURLs.contains { $0.query?.contains("region=us") == true })
    }

    @Test("climbs to a broader rung only when a narrow search finds nothing")
    func searchLadder() async throws {
        let transport = RegionalStubTransport()
        transport.emptyKeywords = ["Secret Diary"]
        transport.responses["catalog/products?"] = try StubTransport.fixture("audible-search")
        let service = AudibleProvider(region: .unitedStates, transport: transport)

        let outcome = try await service.searchWithRegion(
            .init(title: "Secret Diary", author: "Jennifer Lynch")
        )

        #expect(outcome.candidates.isEmpty == false)
        let attempts = transport.requestedURLs.compactMap { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "keywords" }?.value
        }
        #expect(attempts == ["Secret Diary", "Secret Diary Jennifer Lynch"])
    }

    @Test("ranks a matching author above whatever Audible thought was relevant")
    func ranksByAuthor() async throws {
        let (service, _) = try service()
        let outcome = try await service.searchWithRegion(
            .init(title: "twin peaks", author: "Mark Frost")
        )

        #expect(outcome.candidates.first?.authors.contains("Mark Frost") == true)
    }

    @Test("accepts a pasted ASIN or Audible URL, because search cannot find every book",
          arguments: [
              "B01M11U23O",
              "https://www.audible.co.uk/pd/B01M11U23O",
              "  https://www.audible.com/pd/The-Secret-Diary-Audiobook/B01M11U23O?ref=x  "
          ])
    func parsesPastedASIN(text: String) {
        #expect(MetadataQuery.asin(fromPastedText: text) == "B01M11U23O")
    }

    @Test("does not mistake ordinary words for an ASIN")
    func rejectsNonASIN() {
        #expect(MetadataQuery.asin(fromPastedText: "Twin Peaks") == nil)
        #expect(MetadataQuery.asin(fromPastedText: "") == nil)
    }

    @Test("suggests a query from what the file already knows")
    func buildsQueryFromFile() {
        var tags = TagSet()
        tags[.asin] = .string("B01M11U23O")
        #expect(MetadataQuery(from: tags, filename: "book.m4b").asin == "B01M11U23O")

        var sparse = TagSet()
        sparse.title = "The Secret Diary of Laura Palmer"
        sparse[.author] = .string("Jennifer Lynch")
        let query = MetadataQuery(from: sparse, filename: "whatever.m4b")
        #expect(query.title == "The Secret Diary of Laura Palmer")
        #expect(query.author == "Jennifer Lynch")

        // Nothing useful in the tags: fall back to the filename.
        let fromName = MetadataQuery(from: TagSet(), filename: "The Secret Diary of Laura Palmer.m4b")
        #expect(fromName.keywords == "The Secret Diary of Laura Palmer")
    }
}
