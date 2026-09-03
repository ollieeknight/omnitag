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
