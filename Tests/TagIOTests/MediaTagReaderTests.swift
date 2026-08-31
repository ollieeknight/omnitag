import Foundation
import MediaCore
import Testing
@testable import TagIO

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
        #expect(MediaTagReader.canWrite(.mkv) == false, "mkv writing is not built yet")
        #expect(MediaTagReader.canWrite(.mp3) == false, "mp3 writing is not built yet")
    }
}
