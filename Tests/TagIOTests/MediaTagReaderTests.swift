import Foundation
import MediaCore
@testable import TagIO
import Testing

@Suite("MediaTagReader")
struct MediaTagReaderTests {
    @Test("routes MPEG-4 files to AVFoundation")
    func routesMPEG4() async throws {
        let library = try FixtureLibrary()
        let url = try await library.makeTagged(TwinPeaks.theme)
        let item = try await MediaTagReader().read(url)
        #expect(item.tags.title == "Twin Peaks Theme")
    }

    @Test("routes Matroska to the EBML reader AVFoundation cannot replace")
    func routesMatroska() async throws {
        let url = try makeTestMKV(title: "Northwest Passage")
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try await MediaTagReader().read(url)
        #expect(item.tags.title == "Northwest Passage")
        #expect(item.container == .mkv)
    }

    @Test("reports which containers it can read and write")
    func capabilities() {
        #expect(MediaTagReader.canRead(.mkv))
        #expect(MediaTagReader.canRead(.mp3))
        #expect(MediaTagReader.canRead(.ogg) == false)
        #expect(MediaTagReader.canWrite(.m4b))
        #expect(MediaTagReader.canWrite(.mp3))
        #expect(MediaTagReader.canWrite(.mkv))
        #expect(MediaTagReader.canWrite(.flac) == false)
    }
}

@Suite("MediaTagWriter")
struct MediaTagWriterTests {
    @Test("routes mp3 to the ID3 writer and MPEG-4 to AVFoundation")
    func routes() async throws {
        let library = try FixtureLibrary()
        let m4a = try library.makeUntagged(TwinPeaks.theme)
        var tags = TagSet()
        tags.title = "Twin Peaks Theme"
        try await MediaTagWriter().write(tags, to: m4a)
        #expect(try await MediaTagReader().read(m4a).tags.title == "Twin Peaks Theme")

        let mp3 = ID3Builder.mp3(tag: ID3Builder.tag(frames: []))
        defer { try? FileManager.default.removeItem(at: mp3) }
        try await MediaTagWriter().write(tags, to: mp3)
        let written = try #require(try ID3v2.parse(Data(contentsOf: mp3)))
        #expect(written.frames.first { $0.id == "TIT2" }?.textValue == "Twin Peaks Theme")
    }

    @Test("refuses containers with no writer instead of failing silently")
    func refusesUnwritable() async throws {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).flac")
        try Data("fLaC".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: TagIOError.self) { try await MediaTagWriter().write(TagSet(), to: url) }
    }
}
