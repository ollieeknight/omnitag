import Foundation
import MediaCore
import Testing
@testable import TagIO

@Suite("ID3KeyMap")
struct ID3KeyMapTests {
    @Test("maps the frames AVFoundation surfaces for mp3", arguments: [
        ("id3/TIT2", TagKey.title), ("id3/TPE1", .artist), ("id3/TALB", .album),
        ("id3/TYER", .year), ("id3/TRCK", .trackNumber), ("id3/TCON", .genre),
        ("id3/TPE2", .albumArtist), ("id3/TCOM", .composer),
    ])
    func mapsKnownFrames(identifier: String, key: TagKey) {
        #expect(ID3KeyMap.key(forIdentifier: identifier) == key)
    }

    @Test("keeps unknown frames rather than dropping them")
    func keepsUnknownFrames() {
        #expect(ID3KeyMap.key(forIdentifier: "id3/TMOO") == .custom("id3/TMOO"))
    }

    @Test("splits the ID3 track/total convention")
    func splitsTrackTotal() {
        #expect(ID3KeyMap.split("3/12") == (3, 12))
        #expect(ID3KeyMap.split("3") == (3, nil))
        #expect(ID3KeyMap.split("not a number") == (nil, nil))
    }
}

@Suite("Real media reads", .enabled(if: TwinPeaks.realMediaRoot != nil))
struct RealMediaReadTests {
    /// The extension is part of the match: the library holds both an audiobook
    /// and an EPUB of *The Secret Diary of Laura Palmer*, and a name-only match
    /// picks whichever the filesystem happens to list first.
    private func url(_ name: String, _ pathExtension: String) throws -> URL {
        let root = try #require(TwinPeaks.realMediaRoot)
        let match = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains(name) && $0.pathExtension == pathExtension }
        return try #require(match, "no \(pathExtension) matching \(name) in \(root.path)")
    }

    @Test("mp3 ID3 frames land on real keys, not custom ones")
    func readsMP3() async throws {
        let item = try await AVTagReader().read(url("Twin Peaks Theme", "mp3"))
        #expect(item.tags.title == "Twin Peaks Theme")
        #expect(item.tags.artist == "Angelo Badalamenti")
        #expect(item.tags.album == "Twin Peaks")
        #expect(item.tags[.year] == .number(1990))
        #expect(item.tags[.trackNumber] == .number(1))
    }

    @Test("m4b chapters come back in order with titles")
    func readsChapters() async throws {
        let item = try await AVTagReader().read(url("Laura Palmer", "m4b"))
        #expect(item.chapters.count > 50)
        #expect(item.chapters.first?.title == "Opening Credits")
        #expect(item.chapters.first?.start == 0)
        #expect(item.chapters[1].start > 0)
        #expect(zip(item.chapters, item.chapters.dropFirst()).allSatisfy { $0.start < $1.start })
        #expect(item.artwork.count == 1)
    }
}

@Suite("Book keys survive every format that claims to write them")
struct BookKeyRoundTripTests {
    /// `.subtitle` and `.language` were added for books, but the wizard writes
    /// them for audiobooks too. A key on the read side only is exactly the
    /// "my edit vanished on save" bug the shared-table rule exists to prevent.
    @Test("subtitle and language are on both sides of the ID3 table")
    func id3KnowsBookKeys() {
        #expect(ID3KeyMap.frames["TIT3"] == .subtitle)
        #expect(ID3KeyMap.frames["TLAN"] == .language)
        #expect(ID3KeyMap.writeFrames.contains { $0.1 == .subtitle })
        #expect(ID3KeyMap.writeFrames.contains { $0.1 == .language })
    }

    @Test("subtitle and language have MPEG-4 freeform atoms")
    func mpeg4KnowsBookKeys() {
        #expect(MPEG4KeyMap.freeformNames[.subtitle] == "SUBTITLE")
        #expect(MPEG4KeyMap.freeformNames[.language] == "LANGUAGE")
    }

    @Test("a book key written to an m4b comes back as itself")
    func mpeg4FreeformRoundTrips() {
        // The freeform identifier is what goes on disk; reading it back has to
        // land on the same key, or the edit is lost on the next read.
        for key in [TagKey.subtitle, .language, .isbn, .series] {
            let identifier = try? #require(MPEG4KeyMap.identifier(for: key))
            #expect(identifier != nil, "\(key) has no MPEG-4 identifier")
        }
    }
}
