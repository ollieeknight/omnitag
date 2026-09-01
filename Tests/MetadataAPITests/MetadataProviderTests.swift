import Foundation
import MediaCore
import Testing
@testable import MetadataAPI

@Suite("MetadataProvider")
struct MetadataProviderTests {
    /// One OpenLibrary search response, shaped like the real one. Written here
    /// rather than recorded because it is three fields and a cover id.
    private var openLibraryJSON: Data {
        Data("""
        {"docs":[{
          "key":"/works/OL12345W",
          "title":"The Secret Diary of Laura Palmer",
          "author_name":["Jennifer Lynch"],
          "first_publish_year":1990,
          "cover_i":8231856,
          "publisher":["Gallery Books"],
          "isbn":["0671735906","9781451664782"],
          "language":["eng"],
          "subject":["Mystery","Twin Peaks"]
        }]}
        """.utf8)
    }

    private func openLibrary() -> (OpenLibraryProvider, StubTransport) {
        let transport = StubTransport()
        transport.responses["openlibrary.org/search.json"] = openLibraryJSON
        return (OpenLibraryProvider(transport: transport), transport)
    }

    @Test("providers declare which tabs they serve")
    func providersDeclareKinds() {
        #expect(AudibleMetadataProvider().kinds == [.audiobook])
        #expect(OpenLibraryProvider().kinds == [.book])
    }

    @Test("the registry hands the wizard only providers for the current tab")
    func registryFiltersByKind() {
        #expect(MetadataProviders.serving(.book).map(\.id) == ["openlibrary"])
        #expect(MetadataProviders.serving(.audiobook).map(\.id) == ["audible.uk"])
        #expect(MetadataProviders.serving(.movie).isEmpty, "TMDB is not built yet")
    }

    @Test("the Audible provider's name and id follow its region")
    func regionShowsInTheProvider() {
        let us = AudibleMetadataProvider(region: .unitedStates)
        #expect(us.name == "Audible US")
        #expect(us.id == "audible.us")
    }

    @Test("OpenLibrary search returns candidates the wizard can show")
    func openLibrarySearches() async throws {
        let (provider, transport) = openLibrary()
        var query = MetadataQuery()
        query.searchText = "secret diary of laura palmer"

        let results = try await provider.search(query, limit: 20)
        let first = try #require(results.first)
        #expect(first.title == "The Secret Diary of Laura Palmer")
        #expect(first.authors == ["Jennifer Lynch"])
        #expect(first.year == 1990)
        #expect(first.artworkURL?.absoluteString.contains("covers.openlibrary.org") == true)
        #expect(transport.requestedURLs.first?.absoluteString.contains("search.json") == true)
    }

    @Test("an OpenLibrary works key is not shown as if it were an ASIN")
    func worksKeysAreHiddenFromTheRow() async throws {
        let (provider, _) = openLibrary()
        var query = MetadataQuery(); query.searchText = "laura palmer"
        let first = try #require(try await provider.search(query, limit: 1).first)

        #expect(first.id == "/works/OL12345W")
        #expect(first.displayID == nil, "a works key means nothing to a reader")
    }

    @Test("OpenLibrary details write an ISBN, never an ASIN")
    func openLibraryWritesISBNNotASIN() async throws {
        let (provider, _) = openLibrary()
        var query = MetadataQuery(); query.searchText = "laura palmer"
        let candidate = try #require(try await provider.search(query, limit: 1).first)

        let details = try await provider.details(for: candidate)
        let tags = details.book.tagSet

        #expect(tags[.isbn]?.stringValue == "9781451664782", "one unambiguous 13-digit ISBN is safe to offer")
        #expect(tags[.asin] == nil, "an OpenLibrary book has no ASIN")
        #expect(tags[.language]?.stringValue == "eng")
        #expect(tags.genre == "Mystery/Twin Peaks")
        #expect(details.chapters.isEmpty, "an EPUB's contents are the file's own, not the provider's")
    }

    @Test("a work with many editions offers no ISBN, because it would be a guess")
    func ambiguousISBNIsNotInvented() async throws {
        // The real Laura Palmer work lists sixteen ISBNs across six publishers.
        let transport = StubTransport()
        transport.responses["openlibrary.org/search.json"] = Data("""
        {"docs":[{"key":"/works/OL4201255W","title":"The Secret Diary of Laura Palmer",
          "author_name":["Jennifer Lynch"],
          "isbn":["9780140170870","9781451664782","9780671735906","9781849838627"]}]}
        """.utf8)
        let provider = OpenLibraryProvider(transport: transport)
        var query = MetadataQuery(); query.searchText = "laura palmer"
        let candidate = try #require(try await provider.search(query, limit: 1).first)

        let tags = try await provider.details(for: candidate).book.tagSet
        #expect(tags[.isbn] == nil, "picking one edition's ISBN out of four would invent a fact")
        #expect(tags.title == "The Secret Diary of Laura Palmer", "the rest is still offered")
    }

    @Test("a provider that returns nothing is not an error")
    func emptyResultsAreNotErrors() async throws {
        let transport = StubTransport()
        transport.responses["openlibrary.org/search.json"] = Data(#"{"docs":[]}"#.utf8)
        var query = MetadataQuery(); query.searchText = "nothing at all"

        #expect(try await OpenLibraryProvider(transport: transport).search(query, limit: 20).isEmpty)
    }
}
