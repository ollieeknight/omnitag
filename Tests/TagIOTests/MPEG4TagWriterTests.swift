import Foundation
import MediaCore
import LibraryIndex
import Testing
@testable import TagIO

@Suite("MPEG4TagWriter")
struct MPEG4TagWriterTests {
    @Test("every Twin Peaks fixture survives a write/read round-trip",
          arguments: TwinPeaks.all.filter { $0.container.isMPEG4Family })
    func roundTrip(fixture: TwinPeaks.Fixture) async throws {
        let library = try FixtureLibrary()
        let url = try await library.makeTagged(fixture)

        let read = try await AVTagReader().read(url)
        for (key, expected) in fixture.tags.values {
            #expect(read.tags[key] == expected, "key \(key) did not survive")
        }
    }

    @Test("writing preserves audio: duration and playability unchanged")
    func preservesAudio() async throws {
        let library = try FixtureLibrary()
        let url = try library.makeUntagged(TwinPeaks.theme)
        let before = try await AVTagReader().read(url)

        try await MPEG4TagWriter().write(TwinPeaks.theme.tags, to: url)
        let after = try await AVTagReader().read(url)

        let delta = abs((after.duration ?? 0) - (before.duration ?? 0))
        #expect(delta < 0.05, "duration drifted by \(delta)s")
        #expect(after.tags.title == "Twin Peaks Theme")
    }

    @Test("a failed write leaves the original file byte-identical")
    func failedWriteIsAtomic() async throws {
        let library = try FixtureLibrary()
        let url = try await library.makeTagged(TwinPeaks.diary)
        let original = try Data(contentsOf: url)

        // A read-only directory makes the staged temp write fail. The original
        // must survive untouched: no truncation, no half-written export.
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: library.root.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: library.root.path) }

        var edited = TwinPeaks.diary.tags
        edited.title = "Should never land"
        await #expect(throws: (any Error).self) {
            try await MPEG4TagWriter().write(edited, to: url)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("writing archives the previous tags so an undo can restore them")
    func archivesPreviousTags() async throws {
        let library = try FixtureLibrary()
        let url = try await library.makeTagged(TwinPeaks.theme)
        let backups = TagBackupStore(root: library.root.appending(path: "backups"))

        var edited = TwinPeaks.theme.tags
        edited.title = "Falling"
        try await MPEG4TagWriter(backups: backups).write(edited, to: url)

        let restored = try #require(backups.mostRecent(for: url))
        #expect(restored.tags.title == "Twin Peaks Theme")
        #expect(try await AVTagReader().read(url).tags.title == "Falling")
    }

    @Test("refuses containers it cannot write rather than corrupting them")
    func refusesUnsupported() async throws {
        let library = try FixtureLibrary()
        let flac = library.root.appending(path: "unsupported.flac")
        try Data("fLaC".utf8).write(to: flac)

        await #expect(throws: TagIOError.self) {
            try await MPEG4TagWriter().write(TagSet(), to: flac)
        }
    }
}

@Suite("Real media", .enabled(if: TwinPeaks.realMediaRoot != nil))
struct RealMediaTests {
    @Test("reads every file in the developer's own library")
    func readsRealFiles() async throws {
        let root = try #require(TwinPeaks.realMediaRoot)
        let items = try await LibraryScanner().scan(root)
        #expect(!items.isEmpty, "no media found under \(root.path)")

        for item in items {
            let read = try await MediaTagReader().read(item.url)
            #expect(read.duration ?? 0 > 0, "\(item.url.lastPathComponent) has no duration")
            #expect(read.tags.title != nil, "\(item.url.lastPathComponent) has no title")
        }
    }
}
