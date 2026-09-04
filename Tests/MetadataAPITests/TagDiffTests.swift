import Foundation
import MediaCore
@testable import MetadataAPI
import Testing

@Suite("TagDiff")
struct TagDiffTests {
    private let fileTags = TagSet([
        .title: .string("The Secret Diary of Laura Palmer"),
        .author: .string("Jennifer Lynch"),
        .year: .number(2017),
        .genre: .string("Fiction")
    ])

    private let providerTags = TagSet([
        .title: .string("The Secret Diary of Laura Palmer (Twin Peaks)"),
        .author: .string("Jennifer Lynch"),
        .narrator: .string("Sheryl Lee"),
        .year: .number(2017),
        .genre: .string("Literature & Fiction/Mystery, Thriller & Suspense"),
        .publisher: .string("Audible Studios"),
        .asin: .string("B01M11U23O")
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
        Chapter(index: 2, start: 420, duration: 250, title: "August 3, 1984")
    ]

    private let providerChapters: [Chapter] = [
        Chapter(index: 0, start: 0, duration: 125, title: "Chapter 1"),
        Chapter(index: 1, start: 125, duration: 305, title: "Chapter 2"),
        Chapter(index: 2, start: 430, duration: 255, title: "Chapter 3"),
        Chapter(index: 3, start: 685, duration: 200, title: "Chapter 4")
    ]

    @Test("alignment keeps the file's timings and takes the provider's titles")
    func alignedKeepsFileTimings() {
        let rows = ChapterDiff(current: fileChapters, proposed: providerChapters).aligned().rows

        #expect(rows.count == 3, "the file's chapter count wins — its timings are the real ones")
        #expect(rows.map { $0.proposed?.title } == ["Chapter 1", "Chapter 2", "Chapter 3"])
        #expect(rows.map { $0.proposed?.start } == [0, 120, 420])
    }

    @Test("a provider with fewer chapters leaves the unmatched titles alone")
    func fileHasMore() {
        let shortProvider = [Chapter(index: 0, start: 0, duration: 100, title: "Ch 1")]
        let resolved = ChapterDiff(current: fileChapters, proposed: shortProvider).aligned().resolved

        #expect(resolved.map(\.title) == ["Ch 1", "July 22, 1984", "August 3, 1984"])
    }

    @Test("an unchaptered file takes the provider's chapters outright")
    func unchapteredTakesProviderTimings() {
        let unchaptered = [Chapter(index: 0, start: 0, duration: 1000, title: "Book")]
        let resolved = ChapterDiff(current: unchaptered, proposed: providerChapters).aligned().resolved

        #expect(resolved.count == 4)
        #expect(resolved[1].start == 125, "the provider's timing is imported")
    }

    @Test("seconds-long part markers never steal a chapter's title")
    func partMarkersAreRefused() {
        // The real shape of Flight of the Eisenstein: the file has 17 chapters and
        // Audnexus adds two 5-second "Part" markers on top of chapters 8 and 14.
        let file = [
            Chapter(index: 0, start: 16536.94, duration: 2550, title: "07"),
            Chapter(index: 1, start: 19086.95, duration: 2902, title: "08"),
            Chapter(index: 2, start: 21989.07, duration: 2739, title: "09")
        ]
        let provider = [
            Chapter(index: 0, start: 16577.19, duration: 2563, title: "Seven"),
            Chapter(index: 1, start: 19140.26, duration: 4.7, title: "Part Two"),
            Chapter(index: 2, start: 19145.03, duration: 2896, title: "Eight"),
            Chapter(index: 3, start: 22042.10, duration: 2745, title: "Nine")
        ]

        let resolved = ChapterDiff(current: file, proposed: provider).aligned().resolved
        #expect(resolved.map(\.title) == ["Seven", "Eight", "Nine"])
        #expect(resolved.map(\.start) == file.map(\.start), "the file's timings are untouched")
    }

    @Test("pairs chapters by index")
    func pairsByIndex() {
        let diff = ChapterDiff(current: fileChapters, proposed: providerChapters)
        #expect(diff.rows.count == 4, "should cover the longer side")
        #expect(diff.rows[0].current?.title == "Opening Credits")
        #expect(diff.rows[0].proposed?.title == "Chapter 1")
        #expect(diff.rows[3].current == nil, "file has no chapter 4")
        #expect(diff.rows[3].proposed?.title == "Chapter 4")
    }
}

@Suite("TagDiff delta and quick actions")
struct TagDiffDeltaTests {
    private func diff() -> TagDiff {
        var current = TagSet()
        current.title = "Old Title"
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

    @Test("a row edited to blank is skipped, never written as a tag deletion")
    func blankRowsAreSkipped() {
        // `applySnapshot` maps an empty string onto `item.tags[key] = nil`, so
        // carrying a blank row through the delta deleted the file's existing
        // tag. Emptying a row means "leave this one alone", per `delta`'s doc.
        let delta = diff().delta(for: [.narrator, .author])
        #expect(delta[.narrator] == nil)
        #expect(delta.values.count == 1)
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

@Suite("Alignment rewrites the editable rows")
struct ChapterAlignmentTests {
    private let mine = [
        Chapter(index: 0, start: 0, title: "My One"),
        Chapter(index: 1, start: 100, title: "My Two")
    ]
    private let theirs = [
        Chapter(index: 0, start: 5, duration: 95, title: "Their One"),
        Chapter(index: 1, start: 100, duration: 60, title: "Their Two"),
        Chapter(index: 2, start: 160, duration: 40, title: "Their Three")
    ]

    @Test("their titles sit against my times in the editable column")
    func alignmentIsVisibleInTheRows() {
        let rows = ChapterDiff(current: mine, proposed: theirs).aligned().rows
        #expect(rows.count == 2, "the provider's extra chapter is not invented into the file")
        #expect(rows[0].proposed?.title == "Their One")
        #expect(rows[0].proposed?.start == 0, "file timestamp preserved")
    }

    @Test("a hand-edited title survives, because resolved reads the rows")
    func handEditsWin() {
        var diff = ChapterDiff(current: mine, proposed: theirs).aligned()
        diff.rows[0].proposed?.title = "Prologue"
        #expect(diff.resolved.map(\.title) == ["Prologue", "Their Two"])
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
            Chapter(index: 1, start: 30, title: "Chapter One")
        ])
    }

    @Test("rename pattern rewrites the editable column, not the file's chapters")
    func renamePattern() {
        let renamed = diff.renamingAll(with: "Part %n% — %title%")
        #expect(renamed.resolved.map(\.title) == ["Part 1 — Opening Credits", "Part 2 — Chapter One"])
        #expect(renamed.rows[0].current == nil)
    }

    @Test("proximity title matching prevents off-by-one shifts when provider has extra part markers")
    func proximityMatchingAvoidsOffByOne() {
        // File has 3 chapters: Intro at 0s, Chapter 1 at 136s, Chapter 2 at 2090s
        let file = [
            Chapter(index: 0, start: 0, duration: 136, title: "Intro"),
            Chapter(index: 1, start: 136, duration: 1954, title: "1"),
            Chapter(index: 2, start: 2090, duration: 2000, title: "2")
        ]
        // Provider has 4 chapters: Opening Credits at 0s, Part One at 35s, One at 139s, Two at 2095s
        let provider = [
            Chapter(index: 0, start: 0, title: "Opening Credits"),
            Chapter(index: 1, start: 35, title: "Part One: The Betrayer"),
            Chapter(index: 2, start: 139, title: "One"),
            Chapter(index: 3, start: 2095, title: "Two")
        ]

        let resolved = ChapterDiff(current: file, proposed: provider).aligned().resolved

        // File timestamps must be preserved:
        #expect(resolved[0].start == 0)
        #expect(resolved[1].start == 136)
        #expect(resolved[2].start == 2090)

        // File chapter 1 (136s) must match provider chapter 2 ("One" at 139s), NOT "Part One" (at 35s)!
        #expect(resolved[0].title == "Opening Credits")
        #expect(resolved[1].title == "One")
        #expect(resolved[2].title == "Two")
    }

    @Test("rich title detection distinguishes descriptive scene titles from generic numbers")
    func richTitleDetection() {
        let genericChapters = [
            Chapter(index: 0, start: 0, title: "Opening"),
            Chapter(index: 1, start: 100, title: "Chapter 1"),
            Chapter(index: 2, start: 200, title: "Chapter 2"),
            Chapter(index: 3, start: 300, title: "One"),
            Chapter(index: 4, start: 400, title: "Two")
        ]
        #expect(ChapterDiff.hasRichTitles(genericChapters) == false)

        let richChapters = [
            Chapter(index: 0, start: 0, title: "Opening"),
            Chapter(index: 1, start: 40, title: "Quotes"),
            Chapter(index: 2, start: 80, title: "Blood from misunderstanding - Our brethren in ignorance"),
            Chapter(index: 3, start: 1800, title: "Meeting the Invisibles - At the foot of a Golden Throne")
        ]
        #expect(ChapterDiff.hasRichTitles(richChapters) == true)
    }
}

@Suite("Standard field labels")
struct StandardFieldLabelTests {
    @Test("a TV episode's standard fields include the synopsis TMDB returns for it")
    func tvEpisodeHasSynopsis() {
        let keys = TagKey.standardFields(for: .tvEpisode).map(\.key)
        #expect(keys.contains(.synopsis))
    }

    @Test("every standard field carries a hand-written label, not a derived one")
    func labelsAreCurated() {
        // "TMDB ID", not the "Tmdb Id" a camel-case split of the enum case
        // name produces — the wizard's tag table reads these.
        let movie = Dictionary(uniqueKeysWithValues: TagKey.standardFields(for: .movie))
        #expect(movie[.tmdbID] == "TMDB ID")
        #expect(TagKey.label(for: .tmdbID) == "TMDB ID")
        #expect(TagKey.label(for: .showName) == "Show")
    }
}

@Suite("Tag diff row order")
struct TagDiffOrderTests {
    @Test("rows follow the curated field order, not the alphabet")
    func standardOrderWins() throws {
        var proposed = TagSet()
        proposed[.title] = .string("Northwest Passage")
        proposed[.showName] = .string("Twin Peaks")
        proposed[.seasonNumber] = .number(1)
        proposed[.episodeNumber] = .number(1)
        proposed[.director] = .string("David Lynch")

        let diff = TagDiff(current: TagSet(), proposed: proposed, kind: .tvEpisode)
        let order = diff.rows.map(\.key)

        // Alphabetically Director would come first and Title nearly last —
        // which is not how anyone reads an episode.
        #expect(try #require(order.firstIndex(of: .title)) < order.firstIndex(of: .showName)!)
        #expect(try #require(order.firstIndex(of: .showName)) < order.firstIndex(of: .seasonNumber)!)
        #expect(try #require(order.firstIndex(of: .seasonNumber)) < order.firstIndex(of: .episodeNumber)!)
        #expect(try #require(order.firstIndex(of: .episodeNumber)) < order.firstIndex(of: .director)!)
    }

    @Test("a field the file has but the kind does not list still appears, after the standard ones")
    func extrasComeLast() throws {
        var current = TagSet()
        current[.custom("MOOD")] = .string("Ominous")

        let diff = TagDiff(current: current, proposed: TagSet(), kind: .movie)
        let order = diff.rows.map(\.key)

        #expect(order.contains(.custom("MOOD")))
        #expect(try #require(order.firstIndex(of: .title)) < order.firstIndex(of: .custom("MOOD"))!)
    }
}
