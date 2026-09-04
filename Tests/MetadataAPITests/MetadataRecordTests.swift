import Foundation
import MediaCore
@testable import MetadataAPI
import Testing

@Suite("MetadataRecord")
struct MetadataRecordTests {
    @Test("byline prefers authors, then narrators, then director, then show name")
    func bylineFallbackOrder() {
        var record = MetadataRecord(id: "1", title: "T", authors: ["A"], narrators: ["N"], director: "D", showName: "S")
        #expect(record.byline == "A")

        record.authors = []
        #expect(record.byline == "N")

        record.narrators = []
        #expect(record.byline == "D")

        record.director = nil
        #expect(record.byline == "S")

        record.showName = nil
        #expect(record.byline == "")
    }

    @Test("movie fields land in the right tags")
    func movieTagSet() {
        let record = MetadataRecord(
            id: "603", title: "The Matrix", year: 1999, genres: ["Action"],
            director: "Lana Wachowski", studio: "Warner Bros.", contentRating: "R", tmdbID: "603",
            kind: .movie
        )
        let tags = record.tagSet
        #expect(tags[.director]?.stringValue == "Lana Wachowski")
        #expect(tags[.studio]?.stringValue == "Warner Bros.")
        #expect(tags[.contentRating]?.stringValue == "R")
        #expect(tags[.tmdbID]?.stringValue == "603")
        #expect(tags.album == nil, "a movie has no album concept")
    }

    @Test("TV episode fields land in the right tags")
    func tvEpisodeTagSet() {
        let record = MetadataRecord(
            id: "1622", title: "Twin Peaks — Pilot", showName: "Twin Peaks",
            seasonNumber: 1, episodeNumber: 1, episodeTitle: "Pilot", tmdbID: "1622",
            kind: .tvEpisode
        )
        let tags = record.tagSet
        #expect(tags[.showName]?.stringValue == "Twin Peaks")
        #expect(tags[.seasonNumber]?.intValue == 1)
        #expect(tags[.episodeNumber]?.intValue == 1)
        #expect(tags[.episodeTitle]?.stringValue == "Pilot")
        #expect(tags[.tmdbID]?.stringValue == "1622")
        #expect(tags.album == nil, "a TV episode has no album concept")
    }

    @Test("a movie with no director, studio or rating is still not treated as an album")
    func movieWithNoCreditsStillGetsNoAlbum() {
        // The bug this guards against: `tagSet` used to infer "is this a
        // movie/TV record" from director/studio/contentRating/showName/season/
        // episode being set, so a foreign or unrated film with none of those
        // wrongly got `.album` written. `kind` makes this an explicit fact
        // instead of a guess.
        let record = MetadataRecord(id: "1", title: "Some Foreign Film", year: 2020, tmdbID: "1", kind: .movie)
        #expect(record.tagSet.album == nil, "a movie has no album concept, even without director/studio/rating")
    }

    @Test("an audiobook with no authors or narrators still gets an album, grouped by title")
    func audiobookWithNoCreditsStillGetsAlbum() {
        let record = MetadataRecord(id: "1", title: "Some Obscure Recording", kind: .audiobook)
        #expect(record.tagSet.album == "Some Obscure Recording")
    }
}

@Suite("Query from a video filename")
struct VideoFilenameQueryTests {
    @Test("a scene-release episode name searches for the show, not the release tags")
    func episodeReleaseName() {
        let query = MetadataQuery(
            from: TagSet(), filename: "Twin.Peaks.S01E01.Northwest.Passage.1080p.BluRay.x265-GROUP.mkv"
        )
        // TMDB's TV search takes a show name; everything after the SxxEyy is
        // the episode title and the encoder's signature, and both make the
        // search miss.
        #expect(query.searchTerms == "Twin Peaks")
        #expect(query.season == 1)
        #expect(query.episode == 1)
    }

    @Test("the 1x01 spelling parses the same way")
    func alternateEpisodeSpelling() {
        let query = MetadataQuery(from: TagSet(), filename: "Twin Peaks 1x02 - Traces to Nowhere.mkv")
        #expect(query.searchTerms == "Twin Peaks")
        #expect(query.season == 1)
        #expect(query.episode == 2)
    }

    @Test("a movie release name drops the release noise but keeps the year out of the terms")
    func movieReleaseName() {
        let query = MetadataQuery(
            from: TagSet(), filename: "Twin.Peaks.Fire.Walk.with.Me.1992.1080p.BluRay.DTS.x264-AMIABLE.mkv"
        )
        #expect(query.searchTerms == "Twin Peaks Fire Walk with Me")
        #expect(query.year == 1992)
        #expect(query.season == nil)
    }

    @Test("every release term is stripped, not only the first in the list")
    func allReleaseTermsStrip() {
        // A formatter once ate the line continuations out of this pattern,
        // leaving every term but the first two matchable only with padding.
        for term in ["720p", "WEBRip", "HDTV", "x265", "DTS-HD", "10bit", "REMASTERED"] {
            let query = MetadataQuery(from: TagSet(), filename: "Fire Walk with Me \(term) junk.mkv")
            #expect(query.searchTerms == "Fire Walk with Me", "\(term) was not stripped")
        }
    }

    @Test("a plain audiobook filename is unaffected by the video cleaning")
    func audiobookNameUnchanged() {
        let query = MetadataQuery(from: TagSet(), filename: "The Secret Diary of Laura Palmer.m4b")
        #expect(query.searchTerms == "The Secret Diary of Laura Palmer")
        #expect(query.season == nil)
        #expect(query.year == nil)
    }
}

@Suite("Ranking video results")
struct VideoRankingTests {
    private func candidate(_ title: String, year: Int?) -> MetadataCandidate {
        MetadataCandidate(id: title, title: title, authors: [], narrators: [], year: year)
    }

    @Test("a year in the filename outranks TMDB's popularity order for a remake")
    func yearBreaksTheTie() {
        // Verified live: TMDB's /search/movie?query=Dune returns 2021 first,
        // because it ranks by popularity. A file named Dune.1984 wants Lynch.
        let results = [candidate("Dune", year: 2021), candidate("Dune", year: 1984)]
        let query = MetadataQuery(from: TagSet(), filename: "Dune.1984.1080p.BluRay.x264.mkv")

        #expect(query.ranked(results).first?.year == 1984)
    }

    @Test("with no year in the filename the provider's own order is kept")
    func withoutAYearOrderIsUntouched() {
        let results = [candidate("Dune", year: 2021), candidate("Dune", year: 1984)]
        let query = MetadataQuery(from: TagSet(), filename: "Dune.mkv")

        #expect(query.ranked(results).map(\.year) == [2021, 1984])
    }
}
