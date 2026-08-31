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
    private func url(_ name: String) throws -> URL {
        let root = try #require(TwinPeaks.realMediaRoot)
        let match = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains(name) }
        return try #require(match, "no file matching \(name) in \(root.path)")
    }

    @Test("mp3 ID3 frames land on real keys, not custom ones")
    func readsMP3() async throws {
        let item = try await AVTagReader().read(url("Twin Peaks Theme"))
        #expect(item.tags.title == "Twin Peaks Theme")
        #expect(item.tags.artist == "Angelo Badalamenti")
        #expect(item.tags.album == "Twin Peaks")
        #expect(item.tags[.year] == .number(1990))
        #expect(item.tags[.trackNumber] == .number(1))
    }

    @Test("m4b chapters come back in order with titles")
    func readsChapters() async throws {
        let item = try await AVTagReader().read(url("Laura Palmer"))
        #expect(item.chapters.count > 50)
        #expect(item.chapters.first?.title == "Opening Credits")
        #expect(item.chapters.first?.start == 0)
        #expect(item.chapters[1].start > 0)
        #expect(zip(item.chapters, item.chapters.dropFirst()).allSatisfy { $0.start < $1.start })
        #expect(item.artwork.count == 1)
    }
}
