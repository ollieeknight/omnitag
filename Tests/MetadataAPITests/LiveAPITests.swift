import Foundation
import MediaCore
@testable import MetadataAPI
import Testing

/// Opt-in checks against the real APIs: `OMNITAG_LIVE=1 make test`. Off by
/// default so the suite stays offline, but these are what caught every wrong
/// assumption about how Audible's search actually behaves.
@Suite("Live APIs", .enabled(if: ProcessInfo.processInfo.environment["OMNITAG_LIVE"] != nil), .serialized)
struct LiveAPITests {
    @Test("an ASIN resolves to the exact book, with chapters and artwork")
    func asinLookup() async throws {
        let service = AudibleProvider(region: .unitedKingdom)
        let outcome = try await service.searchWithRegion(.init(asin: "B01M11U23O"))
        let candidate = try #require(outcome.candidates.first)

        #expect(candidate.title.contains("Secret Diary of Laura Palmer"))
        #expect(candidate.authors == ["Jennifer Lynch"])

        let details = try await service.details(for: candidate.id, in: outcome.region)
        #expect(details.book.narrators == ["Sheryl Lee"])
        #expect(details.chapters.count > 80)
        #expect(details.book.artworkURL != nil)
    }

    @Test("a UK-first search falls back to the US storefront for a US-only book")
    func regionFallbackIsReal() async throws {
        let service = AudibleProvider(region: .unitedKingdom)
        let outcome = try await service.searchWithRegion(.init(asin: "B01M11U23O"))
        #expect(outcome.region == .unitedStates, "this title is not sold in the UK")
    }

    @Test("keyword search finds books that are in the index")
    func keywordSearch() async throws {
        let service = AudibleProvider(region: .unitedKingdom)
        let outcome = try await service.searchWithRegion(.init(title: "The Secret History of Twin Peaks"))
        #expect(outcome.candidates.contains { $0.authors.contains("Mark Frost") })
    }

    /// Audible's public keyword index does not contain every book it sells:
    /// The Secret Diary of Laura Palmer is reachable by ASIN and invisible to
    /// search, in every phrasing tried. This is why the wizard takes an ASIN or
    /// a pasted Audible URL as a first-class input rather than only free text.
    @Test("some books exist only by ASIN, never in search results")
    func searchIndexHasHoles() async throws {
        let service = AudibleProvider(region: .unitedStates)
        let outcome = try await service.searchWithRegion(.init(keywords: "secret diary laura palmer"))
        #expect(outcome.candidates.contains { $0.id == "B01M11U23O" } == false,
                "if this now passes, Audible indexed the book and the note above can go")
    }
}

@Suite("OpenLibrary, live", .enabled(if: ProcessInfo.processInfo.environment["OMNITAG_LIVE"] == "1"))
struct LiveOpenLibraryTests {
    /// Exists to catch OpenLibrary changing its answer, the same job the
    /// Audible live tests do. Never runs in a normal `make test`.
    @Test("finds the Laura Palmer book and answers with the fields we map")
    func findsTheRealBook() async throws {
        let provider = OpenLibraryProvider()
        var query = MetadataQuery()
        query.searchText = "secret diary of laura palmer"

        let results = try await provider.search(query, limit: 10)
        let match = try #require(
            results.first { $0.title.localizedCaseInsensitiveContains("Secret Diary of Laura Palmer") }
        )
        #expect(match.authors.contains { $0.contains("Lynch") })
        #expect(match.id.hasPrefix("/works/"))

        let tags = try await provider.details(for: match).book.tagSet
        #expect(tags.title?.isEmpty == false)
        #expect(tags[.asin] == nil, "OpenLibrary must never claim an ASIN")
    }

    @Test("the search endpoint still accepts our field list")
    func fieldListStillValid() async throws {
        var query = MetadataQuery()
        query.searchText = "twin peaks"
        let results = try await OpenLibraryProvider().search(query, limit: 5)
        #expect(!results.isEmpty, "OpenLibrary returned nothing for a broad query")
        #expect(results.contains { $0.artworkURL != nil }, "no cover ids came back")
    }
}

/// iTunes needs no key at all, so this suite runs on `OMNITAG_LIVE=1` alone.
@Suite("iTunes, live", .enabled(if: ProcessInfo.processInfo.environment["OMNITAG_LIVE"] == "1"))
struct LiveITunesTests {
    @Test("finds the real Badalamenti theme and answers with the fields we map")
    func findsTheRealTrack() async throws {
        let client = ITunesClient()
        let results = try await client.searchSongs(.init(title: "Twin Peaks Theme Badalamenti"), limit: 10)
        #expect(!results.isEmpty)

        let match = try #require(results.first { $0.authors.contains("Angelo Badalamenti") })
        let tags = await client.details(for: match).book.tagSet

        #expect(tags[.artist]?.stringValue?.contains("Badalamenti") == true)
        #expect(tags[.album]?.stringValue?.isEmpty == false)
        #expect(tags[.trackNumber]?.intValue != nil)
        #expect(tags[.author] == nil, "a track is by an artist, never an author")
    }

    /// The size segment is a CDN path convention, not a documented API — so
    /// it is worth one live check that the upscaled URL actually resolves.
    @Test("the upscaled artwork URL really serves an image")
    func artworkURLResolves() async throws {
        let client = ITunesClient()
        let results = try await client.searchSongs(.init(title: "Twin Peaks Badalamenti"), limit: 10)
        let url = try #require(results.compactMap(\.artworkURL).first)
        #expect(url.absoluteString.contains("1200x1200bb"))

        let (data, status) = try await URLSessionTransport().data(from: url)
        #expect(status == 200)
        #expect(data.count > 10000, "a 1200px cover is not a few hundred bytes")
    }

    /// The developer's own file is named "01 - Twin Peaks Theme.mp3", so this
    /// is the whole path a real user walks: filename to query to a match.
    @Test("the real file's own name finds the real track")
    func realFilenameFindsTheTrack() async throws {
        let query = MetadataQuery(from: TagSet(), filename: "01 - Twin Peaks Theme.mp3")
        let results = try await ITunesClient().searchSongs(query, limit: 20)

        #expect(results.contains { $0.title.localizedCaseInsensitiveContains("Twin Peaks") })
    }

    @Test("an unknown term is an empty result, not an error")
    func unknownTermIsEmpty() async throws {
        let results = try await ITunesClient().searchSongs(.init(title: "zzqqxxnotarealtrack12345"), limit: 5)
        #expect(results.isEmpty)
    }
}

/// Reads the key from `OMNITAG_TMDB_KEY`, never from Keychain — a live test
/// must not depend on what happens to be saved in Preferences on this
/// machine. `export OMNITAG_TMDB_KEY=...` before running; never committed.
@Suite(
    "TMDB, live",
    .enabled(if: ProcessInfo.processInfo.environment["OMNITAG_LIVE"] == "1"
        && ProcessInfo.processInfo.environment["OMNITAG_TMDB_KEY"] != nil)
)
struct LiveTMDBTests {
    private var client: TMDBClient {
        TMDBClient(apiKey: ProcessInfo.processInfo.environment["OMNITAG_TMDB_KEY"])
    }

    @Test("finds the real Fire Walk with Me and answers with the fields we map")
    func findsTheRealMovie() async throws {
        let results = try await client.searchMovies(.init(title: "Twin Peaks Fire Walk with Me"), limit: 5)
        let match = try #require(results.first { $0.year == 1992 })

        let record = try await client.movieDetails(id: match.id)
        #expect(record.director?.contains("Lynch") == true)
        #expect(record.tmdbID == match.id)
    }

    @Test("finds the real Twin Peaks show and its first episode")
    func findsTheRealShowAndEpisode() async throws {
        let results = try await client.searchTV(.init(title: "Twin Peaks"), limit: 5)
        let match = try #require(results.first { $0.year == 1990 })

        let episodes = try await client.seasonEpisodes(showID: match.id, season: 1)
        #expect(!episodes.isEmpty)

        let episode = try await client.episodeDetails(showID: match.id, showName: match.title, season: 1, episode: 1)
        #expect(episode.showName == match.title)
        #expect(episode.seasonNumber == 1)
        #expect(episode.episodeNumber == 1)
    }

    @Test("a scene-release filename searches TMDB successfully with no hand-editing")
    func rawFilenameFindsTheShow() async throws {
        // The whole point of the filename cleaning: what a user actually has
        // on disk is what gets searched, untouched.
        let query = MetadataQuery(
            from: TagSet(), filename: "Twin.Peaks.S01E01.Northwest.Passage.1080p.BluRay.x265-GROUP.mkv"
        )
        let results = try await client.searchTV(query, limit: 5)
        #expect(results.contains { $0.title == "Twin Peaks" && $0.year == 1990 })
        #expect(query.season == 1)
        #expect(query.episode == 1)
    }

    @Test("a movie's filename year picks the right one of two same-titled films")
    func filenameYearPicksTheRightFilm() async throws {
        let query = MetadataQuery(from: TagSet(), filename: "Dune.1984.1080p.BluRay.x264-GROUP.mkv")
        let results = try await client.searchMovies(query, limit: 10)
        // TMDB's own order puts Villeneuve's 2021 film first.
        #expect(query.ranked(results).first?.year == 1984)
    }
}
