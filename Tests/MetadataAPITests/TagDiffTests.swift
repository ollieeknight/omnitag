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
        let diff = TagDiff(current: fileTags, proposed: providerTags, kind: .book)
        let keys = Set(diff.rows.map(\.key))

        // Keys in both, keys only in file, keys only in provider — all present.
        #expect(keys.contains(.title))
        #expect(keys.contains(.genre))
        #expect(keys.contains(.narrator), "provider-only key must appear")
        #expect(keys.contains(.asin), "provider-only key must appear")
    }

    @Test("unchanged fields are reported as unchanged")
    func unchangedRows() {
        let diff = TagDiff(current: fileTags, proposed: providerTags, kind: .book)
        let authorRow = diff.rows.first { $0.key == .author }
        #expect(authorRow?.isChanged == false, "author is identical on both sides")
        let yearRow = diff.rows.first { $0.key == .year }
        #expect(yearRow?.isChanged == false, "year is identical on both sides")
    }

    @Test("changed fields are reported as changed")
    func changedRows() {
        let diff = TagDiff(current: fileTags, proposed: providerTags, kind: .book)
        let titleRow = diff.rows.first { $0.key == .title }
        #expect(titleRow?.isChanged == true, "title differs — provider appends (Twin Peaks)")
        let narratorRow = diff.rows.first { $0.key == .narrator }
        #expect(narratorRow?.isChanged == true, "narrator is new from the provider")
    }

    @Test("merge fills empty fields, does not overwrite existing")
    func merge() {
        let diff = TagDiff(current: fileTags, proposed: providerTags, kind: .book)
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
        let diff = TagDiff(current: fileTags, proposed: providerTags, kind: .book)
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
        let diff = TagDiff(current: fileTags, proposed: providerTags, kind: .book)
        let result = diff.overwriteAll()

        #expect(result.title == "The Secret Diary of Laura Palmer (Twin Peaks)")
        #expect(result[.narrator] == .string("Sheryl Lee"))
        #expect(result[.genre] == .string("Literature & Fiction/Mystery, Thriller & Suspense"))
    }

    @Test("an empty diff against identical tags has no changed rows")
    func identicalTagsProduceNoChanges() {
        let diff = TagDiff(current: fileTags, proposed: fileTags, kind: .book)
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

}

@Suite("TagDiff delta and quick actions")
struct TagDiffDeltaTests {
    private func diff() -> TagDiff {
        var current = TagSet(); current.title = "Old Title"
        var proposed = TagSet()
        proposed.title = "New Title"
        proposed[.author] = .string("Jennifer Lynch")
        proposed[.narrator] = .string("")
        return TagDiff(current: current, proposed: proposed, kind: .book)
    }

    @Test("the delta carries only the ticked keys")
    func deltaIsTickedKeysOnly() {
        let delta = diff().delta(for: [.author])
        #expect(delta[.author]?.stringValue == "Jennifer Lynch")
        #expect(delta[.title] == nil)
    }

    @Test("a row edited to blank is included rather than skipped")
    func blankRowsAreIncluded() {
        let delta = diff().delta(for: [.narrator, .author])
        #expect(delta[.narrator]?.stringValue == "")
        #expect(delta.values.count == 2)
    }

    @Test("fill-empty ticks only the fields the file lacks")
    func mergeAction() {
        let keys = diff().keys(for: .merge)
        #expect(keys.contains(.author))
        #expect(!keys.contains(.title))
    }

    @Test("take-all ticks every field the provider supplied")
    func overwriteAllAction() {
        #expect(diff().keys(for: .overwriteAll) == Set([.title, .author, .narrator]))
        #expect(diff().keys(for: .none).isEmpty)
    }
}

@Suite("ChapterDiff strategies rewrite the rows")
struct ChapterDiffStrategyTests {
    private let mine = [
        Chapter(index: 0, start: 0, title: "My One"),
        Chapter(index: 1, start: 100, title: "My Two"),
    ]
    private let theirs = [
        Chapter(index: 0, start: 5, duration: 95, title: "Their One"),
        Chapter(index: 1, start: 100, duration: 60, title: "Their Two"),
        Chapter(index: 2, start: 160, duration: 40, title: "Their Three"),
    ]

    @Test("keep-my-titles shows their times against my titles in the editable column")
    func strategyIsVisibleInTheRows() {
        let rows = ChapterDiff(current: mine, proposed: theirs)
            .applying(.keepTitlesTakeTimes).rows
        #expect(rows[0].proposed?.title == "My One")
        #expect(rows[0].proposed?.start == 5)
        #expect(rows[2].proposed?.title == "Their Three")
    }

    @Test("a hand-edited title survives, because resolved reads the rows")
    func handEditsWin() {
        var diff = ChapterDiff(current: mine, proposed: theirs).applying(.takeTheirs)
        diff.rows[0].proposed?.title = "Prologue"
        #expect(diff.resolved[0].title == "Prologue")
        #expect(diff.resolved.count == 3)
    }

    @Test("keep-mine trims the rows the strategy drops")
    func keepMineTrims() {
        let diff = ChapterDiff(current: mine, proposed: theirs).applying(.keepMine)
        #expect(diff.resolved.map(\.title) == ["My One", "My Two", "Their Three"])
    }
}

@Suite("Search text routing")
struct SearchTextTests {
    @Test("a pasted Audible URL searches by ASIN, not by keywords")
    func pastedURLBecomesASIN() {
        var query = MetadataQuery()
        query.searchText = "https://www.audible.co.uk/pd/The-Secret-Diary/B01M11U23O?ref=a_search"
        #expect(query.asin == "B01M11U23O")
        #expect(query.keywords == nil)
    }

    @Test("a bare ASIN searches by ASIN")
    func bareASIN() {
        var query = MetadataQuery()
        query.searchText = "  B01M11U23O "
        #expect(query.asin == "B01M11U23O")
    }

    @Test("ordinary words stay keywords, and clear a previous ASIN")
    func wordsStayKeywords() {
        var query = MetadataQuery(asin: "B01M11U23O")
        query.searchText = "the secret diary of laura palmer"
        #expect(query.asin == nil)
        #expect(query.keywords == "the secret diary of laura palmer")
        #expect(query.searchText == "the secret diary of laura palmer")
    }

    @Test("an ASIN query reads back as the ASIN")
    func asinReadsBack() {
        #expect(MetadataQuery(asin: "B01M11U23O").searchText == "B01M11U23O")
    }
}

@Suite("Chapter bulk tools")
struct ChapterBulkToolTests {
    private var diff: ChapterDiff {
        ChapterDiff(current: [], proposed: [
            Chapter(index: 0, start: 0, title: "Opening Credits"),
            Chapter(index: 1, start: 30, title: "Chapter One"),
        ])
    }

    @Test("rename pattern rewrites the editable column, not the file's chapters")
    func renamePattern() {
        let renamed = diff.renamingAll(with: "Part %n% — %title%")
        #expect(renamed.resolved.map(\.title) == ["Part 1 — Opening Credits", "Part 2 — Chapter One"])
        #expect(renamed.rows[0].current == nil)
    }

}
