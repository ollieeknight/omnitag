@testable import EditEngine
import Foundation
import MediaCore
import Testing

@Suite("Renaming files from tags")
struct RenameTests {
    /// A real directory: renaming is a filesystem operation, and a mock of the
    /// filesystem would prove nothing about the one bug that matters — a file
    /// landing on top of another.
    private func makeFolder() throws -> URL {
        let dir = URL(filePath: NSTemporaryDirectory())
            .appending(path: "omnitag-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFile(_ name: String, in dir: URL, title: String, artist: String? = nil) throws -> MediaItem {
        let url = dir.appending(path: name)
        try Data("audio".utf8).write(to: url)
        var tags = TagSet()
        tags.title = title
        tags.artist = artist
        return MediaItem(url: url, kind: .music, container: .m4a, tags: tags)
    }

    // MARK: - Planning

    @Test("a plan renders one row per item, flagging what cannot be renamed")
    func plansRows() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ok = try makeFile("01.m4a", in: dir, title: "Theme", artist: "Badalamenti")
        let noArtist = try makeFile("02.m4a", in: dir, title: "Freshly Squeezed")

        let plan = RenamePlan(items: [ok, noArtist], pattern: FilenamePattern("%artist% - %title%"))

        #expect(plan.rows.count == 2)
        #expect(plan.rows[0].newName == "Badalamenti - Theme.m4a")
        #expect(plan.rows[0].status == .ready)
        #expect(plan.rows[1].status == .missing([.artist]))
        #expect(plan.moves.count == 1)
    }

    @Test("a file already named what the pattern asks for is left alone")
    func unchangedRow() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try makeFile("Theme.m4a", in: dir, title: "Theme")

        let plan = RenamePlan(items: [item], pattern: FilenamePattern("%title%"))
        #expect(plan.rows[0].status == .unchanged)
        #expect(plan.moves.isEmpty)
    }

    @Test("two files that would take the same name are both flagged, neither moved")
    func collisionWithinBatch() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try makeFile("a.m4a", in: dir, title: "Theme")
        let b = try makeFile("b.m4a", in: dir, title: "Theme")

        let plan = RenamePlan(items: [a, b], pattern: FilenamePattern("%title%"))
        #expect(plan.rows.allSatisfy { $0.status == .collision })
        #expect(plan.moves.isEmpty)
    }

    @Test("a name already taken by a file outside the selection is refused")
    func collisionOnDisk() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try makeFile("a.m4a", in: dir, title: "Theme")
        try Data().write(to: dir.appending(path: "Theme.m4a"))

        let plan = RenamePlan(items: [item], pattern: FilenamePattern("%title%"))
        #expect(plan.rows[0].status == .exists)
    }

    @Test("a pattern that renders nothing is refused rather than making a nameless file")
    func emptyName() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try makeFile("a.m4a", in: dir, title: "Theme")

        // Nothing to substitute at all: the pattern is punctuation the
        // sanitiser strips, so there is no name left to give the file.
        #expect(RenamePlan(items: [item], pattern: FilenamePattern("...")).rows[0].status == .empty)
        // A field the file lacks says which field, which is the more useful
        // complaint even though the outcome is the same refusal.
        #expect(RenamePlan(items: [item], pattern: FilenamePattern("%genre%")).rows[0].status
            == .missing([.genre]))
        #expect(RenamePlan(items: [item], pattern: FilenamePattern("%genre%")).moves.isEmpty)
    }

    @Test("the extension is preserved exactly as the file has it")
    func keepsExtension() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try makeFile("a.M4A", in: dir, title: "Theme")
        let plan = RenamePlan(items: [item], pattern: FilenamePattern("%title%"))
        #expect(plan.rows[0].newName == "Theme.M4A")
    }

    // MARK: - Applying

    @Test("applying a rename moves the file and re-keys the library")
    func renamesOnDisk() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try makeFile("01.m4a", in: dir, title: "Theme", artist: "Badalamenti")
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([item])

        let plan = RenamePlan(items: [item], pattern: FilenamePattern("%artist% - %title%"))
        let result = await engine.rename(plan.moves)

        let renamed = dir.appending(path: "Badalamenti - Theme.m4a")
        #expect(result.renamed == 1)
        #expect(result.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(FileManager.default.fileExists(atPath: item.url.path) == false)
        #expect(await engine.item(at: renamed) != nil)
        #expect(await engine.item(at: item.url) == nil)
    }

    @Test("undo moves the file back and restores its old identity")
    func undoRename() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try makeFile("01.m4a", in: dir, title: "Theme")
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([item])
        await engine.rename(RenamePlan(items: [item], pattern: FilenamePattern("%title%")).moves)

        await engine.undo()

        #expect(FileManager.default.fileExists(atPath: item.url.path))
        #expect(await engine.item(at: item.url) != nil)
        #expect(await engine.canRedo)
    }

    @Test("redo re-applies the rename")
    func redoRename() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try makeFile("01.m4a", in: dir, title: "Theme")
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([item])
        await engine.rename(RenamePlan(items: [item], pattern: FilenamePattern("%title%")).moves)
        await engine.undo()
        await engine.redo()

        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "Theme.m4a").path))
    }

    @Test("unsaved edits follow the file to its new name and save to the new path")
    func unsavedEditsSurviveRename() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try makeFile("01.m4a", in: dir, title: "Theme")
        let writer = SpyWriter()
        let engine = EditEngine(writer: writer)
        await engine.load([item])
        await engine.apply(.set(.genre, .string("Soundtrack")), to: [item.url])

        await engine.rename(RenamePlan(items: [item], pattern: FilenamePattern("%title%")).moves)
        let renamed = dir.appending(path: "Theme.m4a")
        #expect(await engine.dirtyURLs == [renamed])

        try await engine.save()
        #expect(await writer.writtenURLs == [renamed])
    }

    @Test("undo after a rename still undoes the tag edit that came before it")
    func undoAcrossRename() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try makeFile("01.m4a", in: dir, title: "Theme")
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([item])
        await engine.apply(.set(.genre, .string("Soundtrack")), to: [item.url])
        await engine.rename(RenamePlan(items: [item], pattern: FilenamePattern("%title%")).moves)

        await engine.undo() // the rename
        await engine.undo() // the tag edit

        #expect(await engine.item(at: item.url)?.tags.genre == nil)
    }

    @Test("a file that vanished from disk fails without taking the batch down")
    func missingFileFails() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gone = try makeFile("gone.m4a", in: dir, title: "Gone")
        let here = try makeFile("here.m4a", in: dir, title: "Here")
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([gone, here])
        try FileManager.default.removeItem(at: gone.url)

        let plan = RenamePlan(items: [gone, here], pattern: FilenamePattern("%title% (renamed)"))
        let result = await engine.rename(plan.moves)

        #expect(result.renamed == 1)
        #expect(result.failures.map(\.url) == [gone.url])
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "Here (renamed).m4a").path))
    }

    // MARK: - Filename → tags

    @Test("parsed tags are applied per file as one undoable batch")
    func appliesPerFileTags() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try makeFile("Badalamenti - Theme.m4a", in: dir, title: "old")
        let b = try makeFile("Cruise - Falling.m4a", in: dir, title: "old")
        let engine = EditEngine(writer: SpyWriter())
        await engine.load([a, b])

        let pattern = FilenamePattern("%artist% - %title%")
        let deltas = Dictionary(uniqueKeysWithValues: [a, b].compactMap { item in
            pattern.parse(item.url.lastPathComponent).map { (item.url, $0) }
        })
        await engine.applyTagDeltas(deltas)

        #expect(await engine.item(at: a.url)?.tags.artist == "Badalamenti")
        #expect(await engine.item(at: b.url)?.tags.title == "Falling")
        await engine.undo()
        #expect(await engine.item(at: a.url)?.tags.title == "old")
        #expect(await engine.item(at: a.url)?.tags.artist == nil)
    }
}
