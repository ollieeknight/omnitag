import Foundation
import Testing
@testable import MediaCore

@Suite("TagSet")
struct TagSetTests {
    @Test("typed accessor round-trips through the untyped store")
    func typedAccessor() {
        var tags = TagSet()
        tags.title = "Kind of Blue"
        #expect(tags[.title] == .string("Kind of Blue"))
        #expect(tags.title == "Kind of Blue")
    }

    @Test("unknown keys survive a round-trip instead of being dropped")
    func customKeysSurvive() {
        var tags = TagSet()
        tags[.custom("TXXX:MOOD")] = .string("blue")
        let copy = tags
        #expect(copy[.custom("TXXX:MOOD")] == .string("blue"))
    }

    @Test("diff reports only changed keys")
    func diff() {
        var before = TagSet(); before.title = "a"; before.artist = "x"
        var after = before; after.title = "b"
        #expect(before.changedKeys(to: after) == [.title])
    }

    @Test("merging many items marks conflicting fields as mixed")
    func mixedValues() {
        var a = TagSet(); a.album = "One"; a.artist = "Miles"
        var b = TagSet(); b.album = "Two"; b.artist = "Miles"
        let common = TagSet.common(of: [a, b])
        #expect(common[.artist] == .string("Miles"))
        #expect(common[.album] == nil)
    }
}

@Suite("ContainerFormat")
struct ContainerFormatTests {
    @Test("classifies by extension, case-insensitively", arguments: [
        ("song.MP3", ContainerFormat.mp3, MediaKind.music),
        ("book.m4b", .m4b, .audiobook),
        ("film.mkv", .mkv, .movie),
        ("track.flac", .flac, .music),
    ])
    func classify(name: String, format: ContainerFormat, kind: MediaKind) {
        let f = ContainerFormat(pathExtension: URL(filePath: name).pathExtension)
        #expect(f == format)
        #expect(f?.defaultKind == kind)
    }

    @Test("ignores non-media files")
    func rejectsJunk() {
        #expect(ContainerFormat(pathExtension: "txt") == nil)
        #expect(ContainerFormat(pathExtension: "") == nil)
    }
}
