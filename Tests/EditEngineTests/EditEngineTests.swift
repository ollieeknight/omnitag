import Foundation
import MediaCore
import Testing
@testable import EditEngine

/// Records writes instead of touching disk: the engine's job is ordering,
/// batching and undo, not I/O.
actor SpyWriter: TagPersisting {
    private(set) var writes: [(URL, TagSet)] = []
    var failing: Set<URL> = []

    func write(_ tags: TagSet, to url: URL) async throws {
        if failing.contains(url) { throw TagWriteError.refused(url) }
        writes.append((url, tags))
    }

    func fail(_ url: URL) { failing.insert(url) }
    var writtenURLs: [URL] { writes.map(\.0) }
    func lastWrite(for url: URL) -> TagSet? { writes.last { $0.0 == url }?.1 }
}

enum TagWriteError: Error { case refused(URL) }

@Suite("EditEngine")
struct EditEngineTests {
    private func item(_ name: String, title: String) -> MediaItem {
        var tags = TagSet(); tags.title = title
        return MediaItem(
            url: URL(filePath: "/library/\(name).m4a"), kind: .music,
            container: .m4a, tags: tags)
    }

    @Test("applying an edit to a selection changes only those items")
    func appliesToSelection() async throws {
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([item("a", title: "A"), item("b", title: "B"), item("c", title: "C")])

        await engine.apply(.set(.genre, .string("Soundtrack")),
                           to: [URL(filePath: "/library/a.m4a"), URL(filePath: "/library/b.m4a")])

        #expect(await engine.item(at: URL(filePath: "/library/a.m4a"))?.tags.genre == "Soundtrack")
        #expect(await engine.item(at: URL(filePath: "/library/b.m4a"))?.tags.genre == "Soundtrack")
        #expect(await engine.item(at: URL(filePath: "/library/c.m4a"))?.tags.genre == nil)
    }

    @Test("undo restores every item a batch touched, in one step")
    func undoIsPerBatch() async throws {
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
    func redo() async throws {
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
    func newEditClearsRedo() async throws {
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
    func clearField() async throws {
        let engine = EditEngine(writer: SpyWriter())
        let url = URL(filePath: "/library/a.m4a")
        await engine.load([item("a", title: "A")])

        await engine.apply(.clear(.title), to: [url])
        #expect(await engine.item(at: url)?.tags.title == nil)
    }

    @Test("find and replace rewrites matching fields only")
    func findReplace() async throws {
        let engine = EditEngine(writer: SpyWriter())
        let urls = [URL(filePath: "/library/a.m4a"), URL(filePath: "/library/b.m4a")]
        await engine.load([item("a", title: "Twin Peaks Theme"), item("b", title: "Laura Palmer")])

        await engine.apply(.replace(.title, find: "Twin Peaks", with: "TP"), to: urls)

        #expect(await engine.item(at: urls[0])?.tags.title == "TP Theme")
        #expect(await engine.item(at: urls[1])?.tags.title == "Laura Palmer")
    }
}
