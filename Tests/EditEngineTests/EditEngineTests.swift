@testable import EditEngine
import Foundation
import MediaCore
import Testing

/// Records writes instead of touching disk: the engine's job is ordering,
/// batching and undo, not I/O.
actor SpyWriter: TagPersisting {
    private(set) var writes: [(URL, TagSet, [Artwork], [Chapter]?)] = []
    var failing: Set<URL> = []

    func write(_ tags: TagSet, artwork: [Artwork], chapters: [Chapter]?, to url: URL) async throws {
        if failing.contains(url) {
            throw TagWriteError.refused(url)
        }
        writes.append((url, tags, artwork, chapters))
    }

    func fail(_ url: URL) {
        failing.insert(url)
    }

    var writtenURLs: [URL] {
        writes.map(\.0)
    }

    func lastWrite(for url: URL) -> TagSet? {
        writes.last { $0.0 == url }?.1
    }
}

enum TagWriteError: Error { case refused(URL) }

@Suite("EditEngine")
struct EditEngineTests {
    private func item(_ name: String, title: String) -> MediaItem {
        var tags = TagSet()
        tags.title = title
        return MediaItem(
            url: URL(filePath: "/library/\(name).m4a"), kind: .music,
            container: .m4a, tags: tags
        )
    }

    @Test("applying an edit to a selection changes only those items")
    func appliesToSelection() async {
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([item("a", title: "A"), item("b", title: "B"), item("c", title: "C")])

        await engine.apply(.set(.genre, .string("Soundtrack")),
                           to: [URL(filePath: "/library/a.m4a"), URL(filePath: "/library/b.m4a")])

        #expect(await engine.item(at: URL(filePath: "/library/a.m4a"))?.tags.genre == "Soundtrack")
        #expect(await engine.item(at: URL(filePath: "/library/b.m4a"))?.tags.genre == "Soundtrack")
        #expect(await engine.item(at: URL(filePath: "/library/c.m4a"))?.tags.genre == nil)
    }

    @Test("undo restores every item a batch touched, in one step")
    func undoIsPerBatch() async {
        let engine = EditEngine(writer: SpyWriter())
        let urls = [URL(filePath: "/library/a.m4a"), URL(filePath: "/library/b.m4a")]
        await engine.load([item("a", title: "A"), item("b", title: "B")])

        await engine.apply(.set(.artist, .string("Badalamenti")), to: urls)
        #expect(await engine.canUndo)
        await engine.undo()

        #expect(await engine.item(at: urls[0])?.tags.artist == nil)
        #expect(await engine.item(at: urls[1])?.tags.artist == nil)
        #expect(await engine.canUndo == false)
        #expect(await engine.canRedo)
    }

    @Test("redo reapplies an undone batch")
    func redo() async {
        let engine = EditEngine(writer: SpyWriter())
        let url = URL(filePath: "/library/a.m4a")
        await engine.load([item("a", title: "A")])

        await engine.apply(.set(.title, .string("Falling")), to: [url])
        await engine.undo()
        await engine.redo()

        #expect(await engine.item(at: url)?.tags.title == "Falling")
        #expect(await engine.canRedo == false)
    }

    @Test("a new edit after an undo drops the redo branch")
    func newEditClearsRedo() async {
        let engine = EditEngine(writer: SpyWriter())
        let url = URL(filePath: "/library/a.m4a")
        await engine.load([item("a", title: "A")])

        await engine.apply(.set(.title, .string("One")), to: [url])
        await engine.undo()
        await engine.apply(.set(.title, .string("Two")), to: [url])

        #expect(await engine.canRedo == false)
        #expect(await engine.item(at: url)?.tags.title == "Two")
    }

    @Test("edits are in-memory until saved, then written once per dirty item")
    func savesOnlyDirtyItems() async throws {
        let writer = SpyWriter()
        let engine = EditEngine(writer: writer)
        let urls = [URL(filePath: "/library/a.m4a"), URL(filePath: "/library/b.m4a")]
        await engine.load([item("a", title: "A"), item("b", title: "B")])

        await engine.apply(.set(.genre, .string("Soundtrack")), to: [urls[0]])
        #expect(await writer.writes.isEmpty, "apply must not touch disk")
        #expect(await engine.dirtyURLs == [urls[0]])

        try await engine.save()
        #expect(await writer.writtenURLs == [urls[0]])
        #expect(await engine.dirtyURLs.isEmpty)
    }

    @Test("a file that fails to save stays dirty and is reported")
    func failedSaveKeepsItemDirty() async throws {
        let writer = SpyWriter()
        let urls = [URL(filePath: "/library/a.m4a"), URL(filePath: "/library/b.m4a")]
        await writer.fail(urls[0])
        let engine = EditEngine(writer: writer)
        await engine.load([item("a", title: "A"), item("b", title: "B")])

        await engine.apply(.set(.genre, .string("Soundtrack")), to: urls)
        let failures = try await engine.save()

        #expect(failures.map(\.url) == [urls[0]])
        #expect(await engine.dirtyURLs == [urls[0]], "the good file must not be retried")
        #expect(await writer.writtenURLs == [urls[1]])
    }

    @Test("clear removes a field across a selection")
    func clearField() async {
        let engine = EditEngine(writer: SpyWriter())
        let url = URL(filePath: "/library/a.m4a")
        await engine.load([item("a", title: "A")])

        await engine.apply(.clear(.title), to: [url])
        #expect(await engine.item(at: url)?.tags.title == nil)
    }

    @Test("find and replace rewrites matching fields only")
    func findReplace() async {
        let engine = EditEngine(writer: SpyWriter())
        let urls = [URL(filePath: "/library/a.m4a"), URL(filePath: "/library/b.m4a")]
        await engine.load([item("a", title: "Twin Peaks Theme"), item("b", title: "Laura Palmer")])

        await engine.apply(.replace(.title, find: "Twin Peaks", with: "TP"), to: urls)

        #expect(await engine.item(at: urls[0])?.tags.title == "TP Theme")
        #expect(await engine.item(at: urls[1])?.tags.title == "Laura Palmer")
    }
}

@Suite("EditEngine snapshot (the wizard path)")
struct EditEngineSnapshotTests {
    private func item(_ name: String, tags: TagSet, artwork: [Artwork] = [], chapters: [Chapter] = []) -> MediaItem {
        MediaItem(
            url: URL(filePath: "/library/\(name).m4b"), kind: .audiobook,
            container: .m4b, tags: tags, chapters: chapters, artwork: artwork
        )
    }

    private func tagged(_ pairs: [TagKey: TagValue]) -> TagSet {
        TagSet(pairs)
    }

    @Test("a snapshot merges the provider's keys without erasing per-file tags")
    func snapshotIsADelta() async {
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([
            item("part1", tags: tagged([.title: .string("Part 1"), .trackNumber: .number(1)])),
            item("part2", tags: tagged([.title: .string("Part 2"), .trackNumber: .number(2)]))
        ])

        await engine.applySnapshot(
            tags: tagged([.author: .string("Jennifer Lynch"), .asin: .string("B01M11U23O")]),
            artwork: [], chapters: nil,
            to: [URL(filePath: "/library/part1.m4b"), URL(filePath: "/library/part2.m4b")]
        )

        let one = await engine.item(at: URL(filePath: "/library/part1.m4b"))
        let two = await engine.item(at: URL(filePath: "/library/part2.m4b"))
        #expect(one?.tags[.author]?.stringValue == "Jennifer Lynch")
        #expect(two?.tags[.asin]?.stringValue == "B01M11U23O")
        // The per-file fields the provider said nothing about must survive.
        #expect(one?.tags.title == "Part 1")
        #expect(two?.tags[.trackNumber]?.intValue == 2)
    }

    @Test("a snapshot with no artwork leaves the existing cover alone")
    func emptyArtworkDoesNotWipe() async {
        let engine = EditEngine(writer: SpyWriter())
        let cover = Artwork(data: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg")
        await engine.load([item("book", tags: tagged([.title: .string("Book")]), artwork: [cover])])

        await engine.applySnapshot(
            tags: tagged([.author: .string("A")]), artwork: [], chapters: nil,
            to: [URL(filePath: "/library/book.m4b")]
        )

        let book = await engine.item(at: URL(filePath: "/library/book.m4b"))
        #expect(book?.artwork == [cover])
    }

    @Test("a snapshot with artwork replaces the cover")
    func artworkReplaces() async {
        let engine = EditEngine(writer: SpyWriter())
        let old = Artwork(data: Data([0xFF, 0xD8]), mimeType: "image/jpeg")
        let new = Artwork(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")
        await engine.load([item("book", tags: TagSet(), artwork: [old])])

        await engine.applySnapshot(
            tags: TagSet(), artwork: [new], chapters: nil,
            to: [URL(filePath: "/library/book.m4b")]
        )

        #expect(await engine.item(at: URL(filePath: "/library/book.m4b"))?.artwork == [new])
    }

    @Test("undo restores tags, artwork and chapters in one step")
    func undoRestoresEverything() async {
        let engine = EditEngine(writer: SpyWriter())
        let old = Artwork(data: Data([0xFF, 0xD8]), mimeType: "image/jpeg")
        let chapter = Chapter(index: 0, start: 0, title: "One")
        await engine.load([
            item("book", tags: tagged([.title: .string("Old")]), artwork: [old], chapters: [chapter])
        ])

        await engine.applySnapshot(
            tags: tagged([.title: .string("New")]),
            artwork: [Artwork(data: Data([0x89, 0x50]), mimeType: "image/png")],
            chapters: [Chapter(index: 0, start: 0, title: "Uno")],
            to: [URL(filePath: "/library/book.m4b")]
        )
        await engine.undo()

        let book = await engine.item(at: URL(filePath: "/library/book.m4b"))
        #expect(book?.tags.title == "Old")
        #expect(book?.artwork == [old])
        #expect(book?.chapters == [chapter])
    }

    @Test("a snapshot that changes nothing does not push an undo step")
    func noOpSnapshot() async {
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([item("book", tags: tagged([.title: .string("Same")]))])

        await engine.applySnapshot(
            tags: tagged([.title: .string("Same")]), artwork: [], chapters: nil,
            to: [URL(filePath: "/library/book.m4b")]
        )

        #expect(await engine.canUndo == false)
    }

    @Test("applySnapshot with clearing removes unprovided tags")
    func snapshotClearsSpecifiedTags() async {
        let engine = EditEngine(writer: SpyWriter())
        let original = tagged([
            .title: .string("Old Title"),
            .composer: .string("Old Composer"),
            .comment: .string("Old Comment")
        ])
        await engine.load([item("book", tags: original)])

        await engine.applySnapshot(
            tags: tagged([.title: .string("New Title"), .author: .string("New Author")]),
            artwork: [], chapters: nil,
            clearing: [.composer, .comment],
            to: [URL(filePath: "/library/book.m4b")]
        )

        let book = await engine.item(at: URL(filePath: "/library/book.m4b"))
        #expect(book?.tags.title == "New Title")
        #expect(book?.tags[.author]?.stringValue == "New Author")
        #expect(book?.tags[.composer] == nil, "composer was cleared")
        #expect(book?.tags[.comment] == nil, "comment was cleared")

        await engine.undo()
        let restored = await engine.item(at: URL(filePath: "/library/book.m4b"))
        #expect(restored?.tags[.composer]?.stringValue == "Old Composer")
        #expect(restored?.tags[.comment]?.stringValue == "Old Comment")
    }
}

@Suite("EditEngine incremental import")
struct EditEngineImportTests {
    private func item(_ name: String) -> MediaItem {
        var tags = TagSet()
        tags.title = name
        return MediaItem(
            url: URL(filePath: "/library/\(name).m4a"), kind: .music,
            container: .m4a, tags: tags
        )
    }

    @Test("adding files keeps earlier unsaved edits dirty and undoable")
    func addingDoesNotResetTheBaseline() async {
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([item("a")])
        await engine.apply(.set(.genre, .string("Soundtrack")), to: [URL(filePath: "/library/a.m4a")])

        await engine.add([item("b")])

        #expect(await engine.dirtyURLs == [URL(filePath: "/library/a.m4a")])
        #expect(await engine.canUndo)
        #expect(await engine.allItems.count == 2)
    }

    @Test("adding a file already in the library does not duplicate or reset it")
    func addingIsIdempotent() async {
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([item("a")])
        await engine.apply(.set(.genre, .string("Jazz")), to: [URL(filePath: "/library/a.m4a")])

        await engine.add([item("a")])

        #expect(await engine.allItems.count == 1)
        #expect(await engine.allItems.first?.tags[.genre]?.stringValue == "Jazz")
    }
}

@Suite("EditEngine artwork, removal and save progress")
struct EditEngineLibraryTests {
    private func item(_ name: String, artwork: [Artwork] = []) -> MediaItem {
        var tags = TagSet()
        tags.title = name
        return MediaItem(
            url: URL(filePath: "/library/\(name).m4b"), kind: .audiobook,
            container: .m4b, tags: tags, artwork: artwork
        )
    }

    private func url(_ name: String) -> URL {
        URL(filePath: "/library/\(name).m4b")
    }

    private let cover = Artwork(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")

    @Test("setting artwork across a selection is one undoable batch")
    func setArtwork() async {
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([item("a"), item("b")])

        await engine.setArtwork([cover], to: [url("a"), url("b")])

        #expect(await engine.item(at: url("a"))?.artwork == [cover])
        #expect(await engine.dirtyURLs.count == 2)
        await engine.undo()
        #expect(await engine.item(at: url("b"))?.artwork.isEmpty == true)
    }

    @Test("clearing artwork is distinct from leaving it alone")
    func clearArtwork() async {
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([item("a", artwork: [cover])])

        await engine.setArtwork([], to: [url("a")])

        #expect(await engine.item(at: url("a"))?.artwork.isEmpty == true)
    }

    @Test("removing files drops them and their pending edits")
    func removeFiles() async {
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([item("a"), item("b")])
        await engine.apply(.set(.genre, .string("Mystery")), to: [url("a")])

        await engine.remove([url("a")])

        #expect(await engine.allItems.map(\.url) == [url("b")])
        #expect(await engine.dirtyURLs.isEmpty)
    }

    @Test("save reports progress once per file, in order")
    func saveProgress() async throws {
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([item("a"), item("b")])
        await engine.apply(.set(.genre, .string("Mystery")), to: [url("a"), url("b")])

        let recorder = ProgressRecorder()
        _ = try await engine.save { url, done, total in
            Task { await recorder.record(url, done, total) }
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.steps.map(\.1) == [1, 2])
        #expect(await recorder.steps.allSatisfy { $0.2 == 2 })
    }
}

actor ProgressRecorder {
    private(set) var steps: [(URL, Int, Int)] = []
    func record(_ url: URL, _ done: Int, _ total: Int) {
        steps.append((url, done, total))
    }
}

@Suite("EditEngine removal keeps surviving history")
struct EditEngineRemovalTests {
    private func item(_ name: String) -> MediaItem {
        MediaItem(url: URL(filePath: "/library/\(name).m4b"), kind: .audiobook, container: .m4b)
    }

    private func url(_ name: String) -> URL {
        URL(filePath: "/library/\(name).m4b")
    }

    @Test("removing one file of a batch leaves the other file's undo intact")
    func batchSurvivesPartialRemoval() async {
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([item("a"), item("b")])
        await engine.apply(.set(.genre, .string("Mystery")), to: [url("a"), url("b")])

        await engine.remove([url("a")])
        await engine.undo()

        #expect(await engine.item(at: url("b"))?.tags[.genre] == nil)
        #expect(await engine.canRedo)
    }

    @Test("a batch that touched only removed files disappears entirely")
    func fullyRemovedBatchIsDropped() async {
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([item("a"), item("b")])
        await engine.apply(.set(.genre, .string("Mystery")), to: [url("a")])

        await engine.remove([url("a")])

        #expect(await engine.canUndo == false)
    }

    @Test("removal reports whether unsaved work was about to be thrown away")
    func removalReportsUnsavedWork() async {
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([item("a"), item("b")])
        await engine.apply(.set(.genre, .string("Mystery")), to: [url("a")])

        #expect(await engine.unsavedCount(among: [url("a"), url("b")]) == 1)
        #expect(await engine.unsavedCount(among: [url("b")]) == 0)
    }
}

@Suite("EditEngine kind and chapter mutations")
struct EditEngineKindAndChapterTests {
    private func item(_ name: String, kind: MediaKind = .music, chapters: [Chapter] = []) -> MediaItem {
        MediaItem(
            url: URL(filePath: "/library/\(name).m4a"),
            kind: kind,
            container: .m4a,
            chapters: chapters
        )
    }

    private func url(_ name: String) -> URL {
        URL(filePath: "/library/\(name).m4a")
    }

    @Test("setKind reassigns kind across selection and undoes")
    func setKindReassignsAndUndoes() async {
        let engine = EditEngine(writer: SpyWriter())
        let u1 = url("a")
        let u2 = url("b")
        await engine.load([item("a", kind: .music), item("b", kind: .music)])

        await engine.setKind(.audiobook, to: [u1, u2])
        #expect(await engine.item(at: u1)?.kind == .audiobook)
        #expect(await engine.item(at: u2)?.kind == .audiobook)
        #expect(await engine.canUndo)

        await engine.undo()
        #expect(await engine.item(at: u1)?.kind == .music)
        #expect(await engine.item(at: u2)?.kind == .music)

        await engine.redo()
        #expect(await engine.item(at: u1)?.kind == .audiobook)
    }

    @Test("applyChapters sorts by timestamp and supports undo/redo")
    func applyChaptersAndUndo() async {
        let engine = EditEngine(writer: SpyWriter())
        let u1 = url("a")
        let initial = [Chapter(index: 0, start: 0, title: "Intro")]
        await engine.load([item("a", chapters: initial)])

        let updated = [
            Chapter(index: 1, start: 30, title: "Chapter 2"),
            Chapter(index: 0, start: 0, title: "Prologue")
        ]
        await engine.applyChapters(updated, to: [u1])

        let applied = await engine.item(at: u1)?.chapters
        #expect(applied?.count == 2)
        #expect(applied?[0].title == "Prologue")
        #expect(applied?[0].start == 0)
        #expect(applied?[1].title == "Chapter 2")
        #expect(applied?[1].start == 30)

        await engine.undo()
        #expect(await engine.item(at: u1)?.chapters == initial)

        await engine.redo()
        #expect(await engine.item(at: u1)?.chapters.count == 2)
    }
}
