import Foundation
import MediaCore
@testable import OmniTagApp
import Testing

@MainActor
@Suite("LibraryModel.detectKind")
struct DetectKindTests {
    @Test("an SxxExx filename is a TV episode regardless of the active tab")
    func seasonEpisodePatternWins() {
        let url = URL(filePath: "/tmp/Show S01E01.mkv")
        #expect(LibraryModel.detectKind(url: url, defaultKind: .music) == .tvEpisode)
        #expect(LibraryModel.detectKind(url: url, defaultKind: .movie) == .tvEpisode)
    }

    @Test("an ambiguous video filename is always a movie, never the current tab")
    func ambiguousVideoDefaultsToMovie() {
        // The bug this guards against: adding a folder while sitting on the
        // TV tab used to silently file an unrelated, ambiguously-named movie
        // as a TV episode, because the classifier trusted whichever sidebar
        // tab happened to be active.
        let url = URL(filePath: "/tmp/Some Movie (1992).mkv")
        #expect(LibraryModel.detectKind(url: url, defaultKind: .tvEpisode) == .movie)
        #expect(LibraryModel.detectKind(url: url, defaultKind: .movie) == .movie)
        #expect(LibraryModel.detectKind(url: url, defaultKind: .music) == .movie)
    }

    @Test("m4b and epub/pdf are classified by extension alone, ignoring the tab")
    func extensionBasedKindsIgnoreTab() {
        #expect(LibraryModel.detectKind(url: URL(filePath: "/tmp/Book.m4b"), defaultKind: .movie) == .audiobook)
        #expect(LibraryModel.detectKind(url: URL(filePath: "/tmp/Book.epub"), defaultKind: .movie) == .book)
        #expect(LibraryModel.detectKind(url: URL(filePath: "/tmp/Book.pdf"), defaultKind: .tvEpisode) == .book)
    }

    @Test("a format with no dedicated heuristic falls back to the active tab")
    func fallsBackToTabForUnclassifiedFormats() {
        // mp3/m4a/wav have no auto-detection heuristic of their own, so the
        // active tab is still a reasonable hint here — unlike movie/TV.
        #expect(LibraryModel.detectKind(url: URL(filePath: "/tmp/Track.mp3"), defaultKind: .music) == .music)
        #expect(LibraryModel.detectKind(url: URL(filePath: "/tmp/Track.mp3"), defaultKind: .audiobook) == .audiobook)
    }
}

@MainActor
@Suite("LibraryModel.kindGuessReason")
struct KindGuessReasonTests {
    @Test("explains an SxxExx match")
    func explainsPatternMatch() {
        let url = URL(filePath: "/tmp/Show S01E01.mkv")
        let reason = LibraryModel.kindGuessReason(url: url)
        #expect(reason?.contains("SxxEyy") == true)
    }

    @Test("explains an ambiguous default to movie")
    func explainsAmbiguousDefault() {
        let url = URL(filePath: "/tmp/Some Movie (1992).mkv")
        let reason = LibraryModel.kindGuessReason(url: url)
        #expect(reason?.contains("defaulted to Movie") == true)
    }

    @Test("no reason for kinds with no ambiguity to explain")
    func noReasonForUnambiguousKinds() {
        #expect(LibraryModel.kindGuessReason(url: URL(filePath: "/tmp/Book.m4b")) == nil)
        #expect(LibraryModel.kindGuessReason(url: URL(filePath: "/tmp/Book.epub")) == nil)
        #expect(LibraryModel.kindGuessReason(url: URL(filePath: "/tmp/Track.mp3")) == nil)
    }
}

@MainActor
@Suite("LibraryModel.visible")
struct LibraryModelVisibleTests {
    private func item(_ name: String, kind: MediaKind = .movie) -> MediaItem {
        var item = MediaItem(url: URL(filePath: "/tmp/\(name).mkv"), kind: kind, container: .mkv)
        item.tags.title = name
        return item
    }

    @Test("reflects the current kind")
    func filtersByKind() {
        let model = LibraryModel()
        model.items = [item("A", kind: .movie), item("B", kind: .tvEpisode)]
        model.kind = .movie
        #expect(model.visible.map(\.displayTitle) == ["A"])

        model.kind = .tvEpisode
        #expect(model.visible.map(\.displayTitle) == ["B"])
    }

    @Test("reflects a later change to items, not a stale snapshot")
    func reflectsItemsChanges() {
        let model = LibraryModel()
        model.kind = .movie
        model.items = [item("A")]
        #expect(model.visible.map(\.displayTitle) == ["A"])

        model.items.append(item("B"))
        #expect(model.visible.map(\.displayTitle) == ["A", "B"])
    }

    @Test("reflects a later change to search")
    func reflectsSearchChanges() {
        let model = LibraryModel()
        model.kind = .movie
        model.items = [item("Alpha"), item("Beta")]
        #expect(model.visible.count == 2)

        model.search = "Alpha"
        #expect(model.visible.map(\.displayTitle) == ["Alpha"])

        model.search = ""
        #expect(model.visible.count == 2)
    }

    @Test("reflects a later change to showUnsavedOnly and dirtyURLs")
    func reflectsUnsavedFilterChanges() {
        let model = LibraryModel()
        model.kind = .movie
        let a = item("A")
        let b = item("B")
        model.items = [a, b]
        model.dirtyURLs = [a.url]

        #expect(model.visible.count == 2, "not filtering yet")
        model.showUnsavedOnly = true
        #expect(model.visible.map(\.displayTitle) == ["A"])

        model.dirtyURLs = [b.url]
        #expect(model.visible.map(\.displayTitle) == ["B"], "must not serve a stale dirty-set result")
    }

    @Test("reflects a later change to sortOrder")
    func reflectsSortOrderChanges() {
        let model = LibraryModel()
        model.kind = .movie
        model.items = [item("Beta"), item("Alpha")]
        #expect(model.visible.map(\.displayTitle) == ["Alpha", "Beta"], "default sort is by title")

        model.sortOrder = [KeyPathComparator(\MediaItem.displayTitle, order: .reverse)]
        #expect(model.visible.map(\.displayTitle) == ["Beta", "Alpha"])
    }
}

@MainActor
@Suite("LibraryModel.count(for:)")
struct LibraryModelCountTests {
    @Test("counts items per kind, so a mixed scan is visible from every tab's badge")
    func countsPerKind() {
        let model = LibraryModel()
        model.items = [
            MediaItem(url: URL(filePath: "/tmp/a.mp3"), kind: .music, container: .mp3),
            MediaItem(url: URL(filePath: "/tmp/b.mkv"), kind: .movie, container: .mkv),
            MediaItem(url: URL(filePath: "/tmp/c.mkv"), kind: .tvEpisode, container: .mkv),
            MediaItem(url: URL(filePath: "/tmp/d.mkv"), kind: .tvEpisode, container: .mkv)
        ]

        #expect(model.count(for: .music) == 1)
        #expect(model.count(for: .movie) == 1)
        #expect(model.count(for: .tvEpisode) == 2)
        #expect(model.count(for: .book) == 0)
    }
}
