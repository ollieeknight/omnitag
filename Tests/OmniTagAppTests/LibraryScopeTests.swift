import Foundation
import MediaCore
@testable import OmniTagApp
import Testing

@MainActor
@Suite("Library scope: All plus the five kinds")
struct LibraryScopeTests {
    private func mixedModel() -> LibraryModel {
        let model = LibraryModel()
        model.items = [
            MediaItem(url: URL(filePath: "/tmp/a.mp3"), kind: .music, container: .mp3),
            MediaItem(url: URL(filePath: "/tmp/b.m4b"), kind: .audiobook, container: .m4b),
            MediaItem(url: URL(filePath: "/tmp/c.mkv"), kind: .movie, container: .mkv),
            MediaItem(url: URL(filePath: "/tmp/d.mkv"), kind: .tvEpisode, container: .mkv),
            MediaItem(url: URL(filePath: "/tmp/e.mkv"), kind: .tvEpisode, container: .mkv)
        ]
        return model
    }

    @Test("All shows every file, whatever its kind")
    func allShowsEverything() {
        let model = mixedModel()
        model.scope = .all

        #expect(model.visible.count == 5)
    }

    @Test("a kind scope shows only that kind")
    func kindScopeFilters() {
        let model = mixedModel()
        model.scope = .kind(.tvEpisode)

        #expect(model.visible.count == 2)
        #expect(model.visible.allSatisfy { $0.kind == .tvEpisode })
    }

    @Test("All counts the whole library")
    func allCountsEverything() {
        let model = mixedModel()

        #expect(model.count(for: .all) == 5)
        #expect(model.count(for: .kind(.tvEpisode)) == 2)
        #expect(model.count(for: .kind(.book)) == 0)
    }

    @Test("search applies inside All as well as inside a kind")
    func searchWorksInAll() {
        let model = mixedModel()
        model.scope = .all
        model.search = "d.mkv"

        #expect(model.visible.count == 1)
    }

    /// `kind` is what the wizard, the inspector's field set and the rename
    /// presets are all built from, so All has to resolve to something.
    @Test("in All, the editing kind follows the selection rather than being ambiguous")
    func editingKindFollowsSelection() {
        let model = mixedModel()
        model.scope = .all
        model.selection = [URL(filePath: "/tmp/c.mkv")]

        #expect(model.kind == .movie)
    }

    @Test("in All with a mixed selection, the editing kind is the one they share, else music")
    func mixedSelectionFallsBack() {
        let model = mixedModel()
        model.scope = .all
        model.selection = [URL(filePath: "/tmp/d.mkv"), URL(filePath: "/tmp/e.mkv")]
        #expect(model.kind == .tvEpisode, "two TV episodes agree")

        model.selection = [URL(filePath: "/tmp/a.mp3"), URL(filePath: "/tmp/c.mkv")]
        #expect(model.kind == .music, "music is the neutral fallback when kinds disagree")
    }

    @Test("a kind scope still reports that kind with nothing selected")
    func kindScopeReportsItsOwnKind() {
        let model = mixedModel()
        model.scope = .kind(.book)

        #expect(model.kind == .book)
    }
}

@Suite("Scope presentation")
struct ScopePresentationTests {
    @Test("All comes first, then the five kinds in order")
    func allCasesOrder() {
        #expect(LibraryScope.allCases.first == .all)
        #expect(LibraryScope.allCases.count == MediaKind.allCases.count + 1)
        #expect(LibraryScope.allCases.dropFirst().map(\.kind) == MediaKind.allCases.map(\.self))
    }

    /// "Music" is a mass noun and "TV Shows" is already plural, so inflecting
    /// a sidebar title gave "5 musics" and "1 TV Shows".
    @Test("every scope names one file without mangling the plural")
    func singularNouns() {
        #expect(LibraryScope.all.singular == "file")
        #expect(LibraryScope.kind(.music).singular == "track")
        #expect(LibraryScope.kind(.tvEpisode).singular == "episode")
    }

    @Test("a row names one file, not the collection it belongs to")
    func rowLabelsAreSingular() {
        #expect(LibraryScope.kind(.tvEpisode).title == "TV Shows", "the sidebar names a collection")
        #expect(LibraryScope.kind(.tvEpisode).rowLabel == "Episode", "a row names one file")
        #expect(LibraryScope.kind(.book).rowLabel == "Book")
    }

    @Test("every scope has a distinct tint, so the sidebar scans by colour")
    func tintsAreDistinct() {
        let kindTints = MediaKind.allCases.map { LibraryScope.kind($0).tint }
        #expect(Set(kindTints.map(String.init(describing:))).count == kindTints.count)
    }
}

@MainActor
@Suite("The By column")
struct DisplayByTests {
    private func item(kind: MediaKind, tags: TagSet) -> MediaItem {
        MediaItem(url: URL(filePath: "/tmp/\(UUID().uuidString)"), kind: kind, container: .mkv, tags: tags)
    }

    @Test("each kind answers 'by whom' with the field it actually has")
    func byFollowsTheKind() {
        var film = TagSet()
        film[.director] = .string("David Lynch")
        #expect(item(kind: .movie, tags: film).displayBy == "David Lynch")

        var episode = TagSet()
        episode[.showName] = .string("Twin Peaks")
        episode[.director] = .string("Duwayne Dunham")
        #expect(item(kind: .tvEpisode, tags: episode).displayBy == "Twin Peaks", "an episode is by its show")

        var track = TagSet()
        track[.artist] = .string("Angelo Badalamenti")
        #expect(item(kind: .music, tags: track).displayBy == "Angelo Badalamenti")

        var book = TagSet()
        book[.author] = .string("Jennifer Lynch")
        #expect(item(kind: .book, tags: book).displayBy == "Jennifer Lynch")
    }

    @Test("a file with nothing to say is empty, not a stale fallback")
    func emptyWhenUnknown() {
        #expect(item(kind: .movie, tags: TagSet()).displayBy.isEmpty)
    }
}

@MainActor
@Suite("Inspector kind under a mixed selection")
struct InspectorKindTests {
    private func model() -> LibraryModel {
        let model = LibraryModel()
        model.items = [
            MediaItem(url: URL(filePath: "/tmp/a.mkv"), kind: .movie, container: .mkv),
            MediaItem(url: URL(filePath: "/tmp/b.mkv"), kind: .tvEpisode, container: .mkv)
        ]
        model.scope = .all
        return model
    }

    @Test("selecting files of one kind reports that kind")
    func agreeingSelection() {
        let model = model()
        model.selection = [URL(filePath: "/tmp/a.mkv")]

        #expect(model.selectedKind == .movie)
    }

    /// The Kind picker read `selectedItems.first?.kind`, so a mixed selection
    /// showed one file's kind as if it spoke for all of them — and choosing
    /// anything then silently rewrote every selected file.
    @Test("a selection whose kinds disagree reports no kind at all")
    func disagreeingSelectionIsNil() {
        let model = model()
        model.selection = [URL(filePath: "/tmp/a.mkv"), URL(filePath: "/tmp/b.mkv")]

        #expect(model.selectedKind == nil)
    }
}
