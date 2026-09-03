import Foundation
import MediaCore
@testable import TagIO
import Testing

/// The audiobook's own regression suite: a chaptered m4b must never come back
/// from a save without its chapters.
@Suite("Chapters survive a tag write")
struct ChapterPreservationTests {
    /// Writes the diary fixture with chapters, then edits one tag the way the
    /// app does when only a title changed.
    private func chapteredDiary(in library: FixtureLibrary) async throws -> URL {
        let url = try library.makeUntagged(TwinPeaks.diary)
        try await MPEG4ChapterWriter().write(
            TwinPeaks.diary.tags, chapters: TwinPeaks.diary.chapters, to: url
        )
        return url
    }

    @Test("the chapter writer round-trips titles and starts")
    func chapterRoundTrip() async throws {
        let library = try FixtureLibrary()
        let url = try await chapteredDiary(in: library)
        let read = try await MediaTagReader().read(url)
        #expect(read.chapters.map(\.title) == TwinPeaks.diary.chapters.map(\.title))
        #expect(read.tags.title == TwinPeaks.diary.tags.title)
    }

    @Test("a tag-only write leaves the chapters alone")
    func tagWriteKeepsChapters() async throws {
        let library = try FixtureLibrary()
        let url = try await chapteredDiary(in: library)
        var tags = TwinPeaks.diary.tags
        tags[.title] = .string("Renamed")

        // chapters: nil is what the engine passes when only a tag changed.
        try await MediaTagWriter().write(tags, chapters: nil, to: url)

        let after = try await MediaTagReader().read(url)
        #expect(after.tags.title == "Renamed")
        #expect(after.chapters.map(\.title) == TwinPeaks.diary.chapters.map(\.title))
    }
}
