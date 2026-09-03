import Foundation
@testable import MediaCore
import Testing

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
        var before = TagSet()
        before.title = "a"
        before.artist = "x"
        var after = before
        after.title = "b"
        #expect(before.changedKeys(to: after) == [.title])
    }

    @Test("merging many items marks conflicting fields as mixed")
    func mixedValues() {
        var a = TagSet()
        a.album = "One"
        a.artist = "Miles"
        var b = TagSet()
        b.album = "Two"
        b.artist = "Miles"
        let common = TagSet.common(of: [a, b])
        #expect(common[.artist] == .string("Miles"))
        #expect(common[.album] == nil)
    }

    @Test("tmdbID round-trips like asin and isbn")
    func tmdbIDRoundTrips() {
        var tags = TagSet()
        tags[.tmdbID] = .string("603")
        #expect(tags[.tmdbID] == .string("603"))
    }
}

@Suite("TagKey.standardFields")
struct StandardFieldsTests {
    @Test("movie fields include the TMDB id")
    func movieHasTmdbID() {
        let keys = TagKey.standardFields(for: .movie).map(\.key)
        #expect(keys.contains(.tmdbID))
    }

    @Test("tvEpisode fields include the TMDB id")
    func tvEpisodeHasTmdbID() {
        let keys = TagKey.standardFields(for: .tvEpisode).map(\.key)
        #expect(keys.contains(.tmdbID))
    }
}

@Suite("ContainerFormat")
struct ContainerFormatTests {
    @Test("classifies by extension, case-insensitively", arguments: [
        ("song.MP3", ContainerFormat.mp3, MediaKind.music),
        ("book.m4b", .m4b, .audiobook),
        ("film.mkv", .mkv, .movie),
        ("track.flac", .flac, .music)
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

@Suite("Artwork MIME sniffing")
struct ArtworkSniffTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 8))
    private let webp = Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 0, 0])

    @Test("recognises the formats a cover actually arrives in")
    func recognisesFormats() {
        #expect(Artwork.sniffMimeType(png) == "image/png")
        #expect(Artwork.sniffMimeType(webp) == "image/webp")
        #expect(Artwork.sniffMimeType(Data([0x47, 0x49, 0x46, 0x38])) == "image/gif")
        #expect(Artwork.sniffMimeType(Data([0xFF, 0xD8, 0xFF])) == "image/jpeg")
        #expect(Artwork.sniffMimeType(Data()) == "image/jpeg")
    }

    @Test("a Data slice sniffs the same as a fresh Data")
    func sliceIsIndexedFromItsOwnStart() {
        // Covers arrive as slices of a parsed frame; absolute indexing would
        // read the wrong bytes here, or trap.
        let sliced = (Data(repeating: 0xAA, count: 100) + webp).dropFirst(100)
        #expect(Artwork.sniffMimeType(sliced) == "image/webp")
        #expect(Artwork.sniffMimeType((Data([0x00]) + png).dropFirst()) == "image/png")
    }
}
