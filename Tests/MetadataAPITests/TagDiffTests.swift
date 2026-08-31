import Foundation
import MediaCore
import Testing
@testable import MetadataAPI

@Suite("TagDiff")
struct TagDiffTests {
    private let fileTags = TagSet([
        .title: .string("The Secret Diary of Laura Palmer"),
        .author: .string("Jennifer Lynch"),
        .year: .number(2017),
        .genre: .string("Fiction"),
    ])

    private let providerTags = TagSet([
        .title: .string("The Secret Diary of Laura Palmer (Twin Peaks)"),
        .author: .string("Jennifer Lynch"),
        .narrator: .string("Sheryl Lee"),
        .year: .number(2017),
        .genre: .string("Literature & Fiction/Mystery, Thriller & Suspense"),
        .publisher: .string("Audible Studios"),
        .asin: .string("B01M11U23O"),
    ])

    @Test("builds rows for every key present in either side")
    func rowsSpanBothSides() {
        let diff = TagDiff(current: fileTags, proposed: providerTags)
        let keys = Set(diff.rows.map(\.key))

        // Keys in both, keys only in file, keys only in provider — all present.
        #expect(keys.contains(.title))
        #expect(keys.contains(.genre))
        #expect(keys.contains(.narrator), "provider-only key must appear")
        #expect(keys.contains(.asin), "provider-only key must appear")
    }

    @Test("unchanged fields are reported as unchanged")
    func unchangedRows() {
        let diff = TagDiff(current: fileTags, proposed: providerTags)
        let authorRow = diff.rows.first { $0.key == .author }
        #expect(authorRow?.isChanged == false, "author is identical on both sides")
        let yearRow = diff.rows.first { $0.key == .year }
        #expect(yearRow?.isChanged == false, "year is identical on both sides")
    }

    @Test("changed fields are reported as changed")
    func changedRows() {
        let diff = TagDiff(current: fileTags, proposed: providerTags)
        let titleRow = diff.rows.first { $0.key == .title }
        #expect(titleRow?.isChanged == true, "title differs — provider appends (Twin Peaks)")
        let narratorRow = diff.rows.first { $0.key == .narrator }
        #expect(narratorRow?.isChanged == true, "narrator is new from the provider")
    }

    @Test("merge fills empty fields, does not overwrite existing")
    func merge() {
        let diff = TagDiff(current: fileTags, proposed: providerTags)
        let merged = diff.merged(into: fileTags)

        // Existing fields are untouched.
        #expect(merged.title == "The Secret Diary of Laura Palmer",
                "merge must not overwrite an existing title")
        #expect(merged[.genre] == .string("Fiction"),
                "merge must not overwrite an existing genre")

        // Empty fields are filled.
        #expect(merged[.narrator] == .string("Sheryl Lee"))
        #expect(merged[.publisher] == .string("Audible Studios"))
        #expect(merged[.asin] == .string("B01M11U23O"))
    }

    @Test("overwrite-selected replaces only the ticked keys")
    func overwriteSelected() {
        let diff = TagDiff(current: fileTags, proposed: providerTags)
        let result = diff.overwriting([.title, .narrator], into: fileTags)

        #expect(result.title == "The Secret Diary of Laura Palmer (Twin Peaks)",
                "ticked key must be overwritten")
        #expect(result[.narrator] == .string("Sheryl Lee"),
                "ticked key must be written")
        #expect(result[.genre] == .string("Fiction"),
                "unticked key must be left alone")
    }

    @Test("overwrite-all replaces everything, dropping keys the provider lacks")
    func overwriteAll() {
        let diff = TagDiff(current: fileTags, proposed: providerTags)
        let result = diff.overwriteAll()

        #expect(result.title == "The Secret Diary of Laura Palmer (Twin Peaks)")
        #expect(result[.narrator] == .string("Sheryl Lee"))
        #expect(result[.genre] == .string("Literature & Fiction/Mystery, Thriller & Suspense"))
    }

    @Test("an empty diff against identical tags has no changed rows")
    func identicalTagsProduceNoChanges() {
        let diff = TagDiff(current: fileTags, proposed: fileTags)
        #expect(diff.rows.filter(\.isChanged).isEmpty)
    }
}

@Suite("ChapterDiff")
struct ChapterDiffTests {
    private let fileChapters: [Chapter] = [
        Chapter(index: 0, start: 0, duration: 120, title: "Opening Credits"),
        Chapter(index: 1, start: 120, duration: 300, title: "July 22, 1984"),
        Chapter(index: 2, start: 420, duration: 250, title: "August 3, 1984"),
    ]

    private let providerChapters: [Chapter] = [
        Chapter(index: 0, start: 0, duration: 125, title: "Chapter 1"),
        Chapter(index: 1, start: 125, duration: 305, title: "Chapter 2"),
        Chapter(index: 2, start: 430, duration: 255, title: "Chapter 3"),
        Chapter(index: 3, start: 685, duration: 200, title: "Chapter 4"),
    ]

    @Test("pairs chapters by index")
    func pairsByIndex() {
        let diff = ChapterDiff(current: fileChapters, proposed: providerChapters)
        #expect(diff.rows.count == 4, "should cover the longer side")
        #expect(diff.rows[0].current?.title == "Opening Credits")
        #expect(diff.rows[0].proposed?.title == "Chapter 1")
        #expect(diff.rows[3].current == nil, "file has no chapter 4")
        #expect(diff.rows[3].proposed?.title == "Chapter 4")
    }

    @Test("keep-mine preserves file titles and times, appends extras from provider")
    func keepMine() {
        let diff = ChapterDiff(current: fileChapters, proposed: providerChapters)
        let result = diff.keepMine()

        #expect(result[0].title == "Opening Credits")
        #expect(result[0].start == 0)
        #expect(result[2].title == "August 3, 1984")
        // Extra chapter from provider is appended.
        #expect(result.count == 4)
        #expect(result[3].title == "Chapter 4")
    }

    @Test("take-theirs replaces everything with the provider's chapters")
    func takeTheirs() {
        let diff = ChapterDiff(current: fileChapters, proposed: providerChapters)
        let result = diff.takeTheirs()

        #expect(result.count == 4)
        #expect(result[0].title == "Chapter 1")
        #expect(result[0].start == 0)
        #expect(result[1].start == 125)
    }

    @Test("keep my titles, take their times")
    func keepTitlesTakeTimes() {
        let diff = ChapterDiff(current: fileChapters, proposed: providerChapters)
        let result = diff.keepTitlesTakeTimes()

        #expect(result[0].title == "Opening Credits", "file's title kept")
        #expect(result[0].start == 0, "provider's start time taken")
        #expect(result[0].duration == 125, "provider's duration taken")
        #expect(result[1].title == "July 22, 1984")
        #expect(result[1].start == 125)
        // Extra chapter beyond file's count takes provider's title too.
        #expect(result[3].title == "Chapter 4")
        #expect(result[3].start == 685)
    }

    @Test("handles file having more chapters than provider")
    func fileHasMore() {
        let shortProvider = [Chapter(index: 0, start: 0, duration: 100, title: "Ch 1")]
        let diff = ChapterDiff(current: fileChapters, proposed: shortProvider)

        #expect(diff.rows.count == 3, "covers the longer side — the file")
        #expect(diff.rows[1].proposed == nil)
        #expect(diff.rows[2].proposed == nil)

        let result = diff.keepMine()
        #expect(result.count == 3, "file's chapters kept in full")
    }

    @Test("rename pattern applies to all chapters")
    func renamePattern() {
        let chapters = fileChapters
        let result = ChapterDiff.applyRenamePattern("Chapter %n%", to: chapters)
        #expect(result[0].title == "Chapter 1")
        #expect(result[1].title == "Chapter 2")
        #expect(result[2].title == "Chapter 3")
        // Times unchanged.
        #expect(result[0].start == 0)
        #expect(result[1].start == 120)
    }

    @Test("shift-all-times offsets every start time")
    func shiftAllTimes() {
        let shifted = ChapterDiff.shiftAllTimes(fileChapters, by: 5.0)
        #expect(shifted[0].start == 5.0)
        #expect(shifted[1].start == 125.0)
        #expect(shifted[2].start == 425.0)
        // Durations are unchanged.
        #expect(shifted[0].duration == 120)
    }

    @Test("negative shift clamps to zero")
    func negativeShiftClampsToZero() {
        let shifted = ChapterDiff.shiftAllTimes(fileChapters, by: -200)
        #expect(shifted[0].start == 0)
        #expect(shifted[1].start == 0, "120 - 200 clamps to 0")
        #expect(shifted[2].start == 220, "420 - 200 = 220")
    }
}
