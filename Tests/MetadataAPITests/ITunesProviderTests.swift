import Foundation
import MediaCore
@testable import MetadataAPI
import Testing

@Suite("ITunesProvider")
struct ITunesProviderTests {
    private static let songSearchJSON = """
    {"resultCount":1,"results":[
    {"wrapperType":"track","kind":"song","trackId":600015397,"collectionId":600015384,
     "artistName":"Angelo Badalamenti","collectionName":"Twin Peaks (Soundtrack From)",
     "trackName":"Twin Peaks Theme",
     "artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music/x.jpg/100x100bb.jpg",
     "releaseDate":"1990-02-06T12:00:00Z","discCount":1,"discNumber":1,
     "trackCount":11,"trackNumber":1,"trackTimeMillis":291933,
     "primaryGenreName":"Soundtrack"}]}
    """

    private func provider() -> (ITunesProvider, StubTransport) {
        let transport = StubTransport()
        transport.responses["search"] = Data(Self.songSearchJSON.utf8)
        return (ITunesProvider(transport: transport), transport)
    }

    @Test("serves music, and only music")
    func servesMusic() {
        #expect(ITunesProvider().kinds == [.music])
    }

    @Test("music now has a provider, so the wizard opens on the Music tab")
    func registeredForMusic() {
        let serving = MetadataProviders.serving(.music)
        #expect(serving.contains { $0.id == "itunes" })
    }

    @Test("adding a music provider leaves every other kind's list alone")
    func otherKindsUnchanged() {
        #expect(MetadataProviders.serving(.audiobook).allSatisfy { $0.id != "itunes" })
        #expect(MetadataProviders.serving(.movie).contains { $0.id == "tmdb" })
        #expect(MetadataProviders.serving(.book).contains { $0.id == "openlibrary" })
    }

    @Test("needs no API key, unlike TMDB")
    func needsNoKey() {
        #expect(!ITunesProvider().isMissingAPIKey)
    }

    @Test("has no episode picker — that is TMDB's TV flow")
    func noEpisodePicker() {
        #expect(!ITunesProvider().hasEpisodePicker)
    }

    @Test("a search returns song candidates through the protocol")
    func searchThroughProtocol() async throws {
        let (provider, _) = provider()

        let results = try await provider.search(.init(title: "Twin Peaks Theme"), kind: .music, limit: 20)

        #expect(results.count == 1)
        #expect(results.first?.title == "Twin Peaks Theme")
    }

    @Test("details resolve without a second network request")
    func detailsCostNoRequest() async throws {
        let (provider, transport) = provider()
        let candidate = try #require(
            try await provider.search(.init(title: "x"), kind: .music, limit: 20).first
        )
        let countAfterSearch = transport.requestedURLs.count

        let details = try await provider.details(for: candidate, kind: .music)

        // `/lookup?id=` was checked live and returns nothing `/search` does
        // not, so a detail round trip would buy a request and no fields.
        #expect(transport.requestedURLs.count == countAfterSearch)
        #expect(details.book.tagSet[.album]?.stringValue == "Twin Peaks (Soundtrack From)")
    }

    /// The record cache was briefly `static`, so two clients in one process
    /// keyed by the same track id resolved to whichever searched last — a bug
    /// that would have shown up as one window's tags leaking into another's.
    @Test("two providers searching the same track id do not overwrite each other")
    func cachesAreNotShared() async throws {
        let compilation = StubTransport()
        compilation.responses["search"] = Data("""
        {"results":[{"trackId":600015397,"trackName":"Twin Peaks Theme",
         "artistName":"Angelo Badalamenti","collectionName":"Synthesizer Greatest 6",
         "collectionArtistName":"Various Artists"}]}
        """.utf8)
        let album = StubTransport()
        album.responses["search"] = Data("""
        {"results":[{"trackId":600015397,"trackName":"Twin Peaks Theme",
         "artistName":"Angelo Badalamenti","collectionName":"Twin Peaks (Soundtrack From)"}]}
        """.utf8)

        let first = ITunesProvider(transport: compilation)
        let second = ITunesProvider(transport: album)
        let a = try #require(try await first.search(.init(title: "x"), kind: .music, limit: 5).first)
        let b = try #require(try await second.search(.init(title: "x"), kind: .music, limit: 5).first)

        let aTags = try await first.details(for: a, kind: .music).book.tagSet
        let bTags = try await second.details(for: b, kind: .music).book.tagSet

        #expect(aTags[.albumArtist]?.stringValue == "Various Artists")
        #expect(bTags[.albumArtist]?.stringValue == "Angelo Badalamenti")
        #expect(aTags[.album]?.stringValue == "Synthesizer Greatest 6")
        #expect(bTags[.album]?.stringValue == "Twin Peaks (Soundtrack From)")
    }

    @Test("a track carries no chapters — that is an audiobook's shape")
    func noChapters() async throws {
        let (provider, _) = provider()
        let candidate = try #require(
            try await provider.search(.init(title: "x"), kind: .music, limit: 20).first
        )

        #expect(try await provider.details(for: candidate, kind: .music).chapters.isEmpty)
    }
}
