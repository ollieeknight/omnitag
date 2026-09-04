import Foundation
import MediaCore
@testable import OmniTagApp
import Testing

/// A `UserDefaults` suite of its own, so a test never reads or writes the
/// developer's real preferences. Removed in `deinit`.
private final class ScratchDefaults {
    let name = "omnitag-tests-\(UUID().uuidString)"

    deinit { UserDefaults.standard.removePersistentDomain(forName: name) }
}

@Suite("Remembered library roots")
struct LibraryRootsTests {
    @Test("a folder that was added comes back on the next launch")
    func rootsSurviveALaunch() {
        let scratch = ScratchDefaults()
        let store = LibraryRootStore(suiteName: scratch.name)
        let folder = URL(filePath: "/tmp/omnitag-library")

        store.remember([folder])

        // A second store over the same defaults is what the next launch sees.
        #expect(LibraryRootStore(suiteName: scratch.name).roots == [folder])
    }

    @Test("the same folder added twice is remembered once")
    func rootsAreDeduplicated() {
        let scratch = ScratchDefaults()
        let store = LibraryRootStore(suiteName: scratch.name)
        let folder = URL(filePath: "/tmp/omnitag-library")

        store.remember([folder])
        store.remember([folder])

        #expect(store.roots == [folder])
    }

    @Test("a folder deleted since the last launch is dropped, not re-scanned forever")
    func vanishedRootsAreForgotten() throws {
        let scratch = ScratchDefaults()
        let store = LibraryRootStore(suiteName: scratch.name)

        let real = URL.temporaryDirectory.appending(path: "omnitag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        let gone = URL(filePath: "/tmp/omnitag-does-not-exist-\(UUID().uuidString)")

        store.remember([real, gone])

        // `existing` is what a launch actually re-scans: a folder the user
        // moved or deleted must not resurrect an error on every launch.
        #expect(store.existingRoots == [real])
    }

    @Test("removing the last file forgets the folders, so a relaunch stays empty")
    func emptyingTheLibraryForgetsItsRoots() async throws {
        let scratch = ScratchDefaults()
        let folder = URL.temporaryDirectory.appending(path: "omnitag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // An .avi is enough: the scanner types it by extension, and nothing
        // here reads its tags.
        try Data([0]).write(to: folder.appending(path: "Some Film (1999).avi"))

        let model = await LibraryModel()
        await MainActor.run { model.roots = LibraryRootStore(suiteName: scratch.name) }
        await model.load(folder)
        #expect(await model.items.count == 1)
        #expect(await !model.roots.roots.isEmpty, "adding a folder remembers it")

        // The scanner's URL, not the one written above: /var is a symlink to
        // /private/var, and the selection is keyed by URL.
        let scanned = await model.items[0].url
        await MainActor.run { model.selection = [scanned] }
        await model.removeSelected()

        #expect(await model.items.isEmpty)
        // Without this the next launch re-scans the folder and the file the
        // user just removed comes straight back.
        #expect(await model.roots.roots.isEmpty)
    }

    @Test("a remembered folder is re-scanned on the next launch")
    func restoreRebuildsTheLibrary() async throws {
        let scratch = ScratchDefaults()
        let folder = URL.temporaryDirectory.appending(path: "omnitag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([0]).write(to: folder.appending(path: "Some Film (1999).avi"))

        let first = await LibraryModel()
        await MainActor.run { first.roots = LibraryRootStore(suiteName: scratch.name) }
        await first.load(folder)
        #expect(await first.items.count == 1)

        // A second model over the same defaults is what the next launch is.
        let suite = scratch.name
        let next = await LibraryModel()
        await MainActor.run { next.roots = LibraryRootStore(suiteName: suite) }
        #expect(await next.items.isEmpty, "a fresh model starts empty")

        await next.restore()

        #expect(await next.items.count == 1, "the folder was re-scanned on launch")
    }

    @Test("a restored library opens on a scope that has files in it")
    func restoreLandsOnANonEmptyScope() async throws {
        let scratch = ScratchDefaults()
        let folder = URL.temporaryDirectory.appending(path: "omnitag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([0]).write(to: folder.appending(path: "A Film (2001).mkv"))

        let suite = scratch.name
        let model = await LibraryModel()
        await MainActor.run { model.roots = LibraryRootStore(suiteName: suite) }
        await model.load(folder)

        let next = await LibraryModel()
        await MainActor.run { next.roots = LibraryRootStore(suiteName: suite) }
        await next.restore()

        // All is the default and always has the files in it, so a restored
        // library never lands on an empty tab. The guard still matters for a
        // library restored while a kind scope was remembered.
        #expect(await next.scope == .all)
        #expect(await next.visible.count == 1)
    }

    @Test("forgetting everything empties the list")
    func forgetClearsRoots() {
        let scratch = ScratchDefaults()
        let store = LibraryRootStore(suiteName: scratch.name)
        store.remember([URL(filePath: "/tmp/a"), URL(filePath: "/tmp/b")])

        store.forgetAll()

        #expect(store.roots.isEmpty)
        #expect(LibraryRootStore(suiteName: scratch.name).roots.isEmpty)
    }
}
