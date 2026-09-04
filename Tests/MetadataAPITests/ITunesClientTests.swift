import Foundation
import MediaCore
@testable import MetadataAPI
import Testing

@Suite("iTunesClient")
struct ITunesClientTests {
    private func client(status: Int = 200) -> (ITunesClient, StubTransport) {
        let transport = StubTransport()
        transport.status = status
        return (ITunesClient(transport: transport), transport)
    }

    /// Trimmed from a real `https://itunes.apple.com/search?entity=song`
    /// response — the fields OmniTag maps, in the shapes the API returns.
    private static let songSearchJSON = """
    {"resultCount":2,"results":[
    {"wrapperType":"track","kind":"song","trackId":600015397,"collectionId":600015384,
     "artistName":"Angelo Badalamenti","collectionName":"Twin Peaks (Soundtrack From)",
     "trackName":"Twin Peaks Theme","collectionArtistName":"Various Artists",
     "artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music/x.jpg/100x100bb.jpg",
     "releaseDate":"1990-02-06T12:00:00Z","discCount":1,"discNumber":1,
     "trackCount":11,"trackNumber":1,"trackTimeMillis":291933,
     "primaryGenreName":"Soundtrack"},
    {"wrapperType":"track","kind":"song","trackId":299503750,"collectionId":299503747,
     "artistName":"Angelo Badalamenti","collectionName":"Twin Peaks - Single",
     "trackName":"Twin Peaks (A-Version)",
     "releaseDate":"2008-12-12T12:00:00Z","trackCount":2,"trackNumber":1,
     "trackTimeMillis":180000,"primaryGenreName":"Dance"}]}
    """

    @Test("a song search returns one candidate per track")
    func songSearch() async throws {
        let (client, transport) = client()
        transport.responses["search"] = Data(Self.songSearchJSON.utf8)

        let results = try await client.searchSongs(.init(title: "Twin Peaks Theme"), limit: 20)

        #expect(results.count == 2)
        let first = try #require(results.first)
        #expect(first.id == "600015397", "the track id, not the album's — a candidate names one song")
        #expect(first.title == "Twin Peaks Theme")
        #expect(first.authors == ["Angelo Badalamenti"])
        #expect(first.year == 1990)
        #expect(first.runtimeMinutes == 4, "291933 ms is 4 minutes 52")
    }

    @Test("the request asks for songs, and passes the search term through")
    func requestShape() async throws {
        let (client, transport) = client()
        transport.responses["search"] = Data(Self.songSearchJSON.utf8)

        _ = try await client.searchSongs(.init(title: "Laura Palmer's Theme"), limit: 5)

        let url = try #require(transport.requestedURLs.first?.absoluteString)
        #expect(url.contains("entity=song"))
        #expect(url.contains("limit=5"))
        #expect(url.contains("Laura") && url.contains("Palmer"))
    }

    @Test("a track's record carries every field the music tag set uses")
    func songRecord() async throws {
        let (client, transport) = client()
        transport.responses["search"] = Data(Self.songSearchJSON.utf8)

        let record = try #require(try await client.searchSongs(.init(title: "x"), limit: 20).first)
        let details = try await client.details(for: record)
        let tags = details.book.tagSet

        #expect(tags[.title]?.stringValue == "Twin Peaks Theme")
        #expect(tags[.artist]?.stringValue == "Angelo Badalamenti")
        #expect(tags[.album]?.stringValue == "Twin Peaks (Soundtrack From)")
        #expect(tags[.albumArtist]?.stringValue == "Various Artists")
        #expect(tags[.trackNumber]?.intValue == 1)
        #expect(tags[.trackTotal]?.intValue == 11)
        #expect(tags[.discNumber]?.intValue == 1)
        #expect(tags[.year]?.intValue == 1990)
        #expect(tags[.genre]?.stringValue == "Soundtrack")
    }

    /// The album artist is a real distinction — a compilation's tracks each
    /// have their own artist but share one album artist. Falling back to the
    /// track artist keeps a normal album's tags complete.
    @Test("a track with no collection artist uses its own artist as album artist")
    func albumArtistFallsBack() async throws {
        let (client, transport) = client()
        transport.responses["search"] = Data(Self.songSearchJSON.utf8)

        let results = try await client.searchSongs(.init(title: "x"), limit: 20)
        let single = try #require(results.last)
        let tags = try await client.details(for: single).book.tagSet

        #expect(tags[.albumArtist]?.stringValue == "Angelo Badalamenti")
    }

    /// iTunes serves art from a CDN whose size is a path segment, so the
    /// 100px thumbnail the API returns can be asked for at cover resolution.
    @Test("artwork is requested at cover resolution, not the API's 100px thumbnail")
    func artworkIsUpscaled() async throws {
        let (client, transport) = client()
        transport.responses["search"] = Data(Self.songSearchJSON.utf8)

        let candidate = try #require(try await client.searchSongs(.init(title: "x"), limit: 20).first)

        #expect(candidate.artworkURL?.absoluteString.hasSuffix("/1200x1200bb.jpg") == true)
    }

    @Test("a track with no artwork has no artwork URL, not a broken one")
    func missingArtworkIsNil() async throws {
        let (client, transport) = client()
        transport.responses["search"] = Data(Self.songSearchJSON.utf8)

        let single = try #require(try await client.searchSongs(.init(title: "x"), limit: 20).last)

        #expect(single.artworkURL == nil)
    }

    /// `authors` is how every provider names "the people responsible", but a
    /// track's person is its *artist*. Writing `.author` as well would put an
    /// audiobook field on every music file.
    @Test("a music record writes artist, never author")
    func musicHasNoAuthorTag() async throws {
        let (client, transport) = client()
        transport.responses["search"] = Data(Self.songSearchJSON.utf8)

        let candidate = try #require(try await client.searchSongs(.init(title: "x"), limit: 20).first)
        let tags = try await client.details(for: candidate).book.tagSet

        #expect(tags[.artist]?.stringValue == "Angelo Badalamenti")
        #expect(tags[.author] == nil, "author is a book field")
        #expect(tags[.narrator] == nil, "narrator is an audiobook field")
    }

    // MARK: failures

    @Test("an empty query never reaches the network")
    func emptyQuery() async throws {
        let (client, transport) = client()

        await #expect(throws: MetadataError.emptyQuery) {
            _ = try await client.searchSongs(.init(), limit: 20)
        }
        #expect(transport.requestedURLs.isEmpty)
    }

    @Test("a non-200 response is reported as a server error")
    func serverError() async throws {
        let (client, transport) = client(status: 503)
        transport.responses["search"] = Data(Self.songSearchJSON.utf8)

        await #expect(throws: MetadataError.server(status: 503)) {
            _ = try await client.searchSongs(.init(title: "x"), limit: 20)
        }
    }

    @Test("a malformed body is reported as such, not as an empty result")
    func malformedResponse() async throws {
        let (client, transport) = client()
        transport.responses["search"] = Data("not json".utf8)

        await #expect(throws: (any Error).self) {
            _ = try await client.searchSongs(.init(title: "x"), limit: 20)
        }
    }

    /// iTunes answers an unknown term with `{"resultCount":0,"results":[]}`
    /// and a 200 — an empty result, not an error.
    @Test("no matches is an empty list, not a failure")
    func noMatches() async throws {
        let (client, transport) = client()
        transport.responses["search"] = Data(#"{"resultCount":0,"results":[]}"#.utf8)

        #expect(try await client.searchSongs(.init(title: "zzzq"), limit: 20).isEmpty)
    }
}
