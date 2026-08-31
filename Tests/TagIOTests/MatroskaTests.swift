import Foundation
import MediaCore
import Testing
@testable import TagIO

/// Builds EBML by hand so the parser is tested against bytes we control, not
/// against whatever a muxer happened to emit. Small enough to read; that is the
/// point — a fixture you cannot read proves nothing.
struct EBMLBuilder {
    static func vint(_ value: UInt64) -> [UInt8] {
        for width in 1...8 where value < (UInt64(1) << (7 * width)) - 1 {
            var bytes = [UInt8]()
            for index in (0..<width).reversed() {
                bytes.append(UInt8((value >> (8 * index)) & 0xFF))
            }
            bytes[0] |= UInt8(0x80 >> (width - 1))
            return bytes
        }
        fatalError("size too large for a test fixture")
    }

    static func id(_ value: UInt64) -> [UInt8] {
        var bytes = [UInt8]()
        var remaining = value
        while remaining > 0 { bytes.insert(UInt8(remaining & 0xFF), at: 0); remaining >>= 8 }
        return bytes
    }

    static func element(_ elementID: UInt64, _ payload: [UInt8]) -> [UInt8] {
        id(elementID) + vint(UInt64(payload.count)) + payload
    }

    static func string(_ elementID: UInt64, _ value: String) -> [UInt8] {
        element(elementID, Array(value.utf8))
    }

    static func uint(_ elementID: UInt64, _ value: UInt64) -> [UInt8] {
        var bytes = [UInt8]()
        var remaining = value
        repeat { bytes.insert(UInt8(remaining & 0xFF), at: 0); remaining >>= 8 } while remaining > 0
        return element(elementID, bytes)
    }

    static func double(_ elementID: UInt64, _ value: Double) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.bigEndian) { element(elementID, Array($0)) }
    }

    static func simpleTag(_ name: String, _ value: String) -> [UInt8] {
        element(0x67C8, string(0x45A3, name) + string(0x4487, value))
    }

    static func tag(targetType: UInt64?, trackUID: UInt64? = nil, _ tags: [[UInt8]]) -> [UInt8] {
        var targetBody = targetType.map { uint(0x68CA, $0) } ?? []
        if let trackUID { targetBody += uint(0x63C5, trackUID) }
        let targets = targetBody.isEmpty ? [] : element(0x63C0, targetBody)
        return element(0x7373, targets + tags.flatMap { $0 })
    }

    static func chapter(start: UInt64, title: String) -> [UInt8] {
        element(0xB6, uint(0x91, start) + element(0x80, string(0x85, title)))
    }
}

/// A synthetic Twin Peaks episode: enough Matroska to exercise every element
/// the reader cares about, none of the video.
func makeTestMKV(
    title: String = "Northwest Passage",
    duration: Double = 5400,
    tags: [[UInt8]] = [],
    chapters: [[UInt8]] = []
) throws -> URL {
    let header = EBMLBuilder.element(0x1A45DFA3, EBMLBuilder.string(0x4282, "matroska"))
    let info = EBMLBuilder.element(0x1549A966,
        EBMLBuilder.uint(0x2AD7B1, 1_000_000)          // TimestampScale: ms
        + EBMLBuilder.double(0x4489, duration * 1000)  // Duration, in scale units
        + EBMLBuilder.string(0x7BA9, title))
    var segmentBody = info
    if !chapters.isEmpty {
        segmentBody += EBMLBuilder.element(0x1043A770,
            EBMLBuilder.element(0x45B9, chapters.flatMap { $0 }))
    }
    if !tags.isEmpty {
        segmentBody += EBMLBuilder.element(0x1254C367, tags.flatMap { $0 })
    }
    // A Cluster full of "frames" the reader must skip without reading.
    segmentBody += EBMLBuilder.element(0x1F43B675, [UInt8](repeating: 0x42, count: 4096))

    let file = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mkv")
    try Data(header + EBMLBuilder.element(0x18538067, segmentBody)).write(to: file)
    return file
}

@Suite("MatroskaReader")
struct MatroskaTests {
    @Test("reads title and duration from the Info element")
    func readsInfo() async throws {
        let url = try makeTestMKV(title: "Northwest Passage", duration: 5400)
        defer { try? FileManager.default.removeItem(at: url) }

        let item = try MatroskaReader().read(url)
        #expect(item.tags.title == "Northwest Passage")
        #expect(abs((item.duration ?? 0) - 5400) < 0.01)
        #expect(item.container == .mkv)
    }

    @Test("maps Matroska tag names onto the shared key set")
    func readsTags() async throws {
        let url = try makeTestMKV(tags: [
            EBMLBuilder.tag(targetType: 50, [
                EBMLBuilder.simpleTag("TITLE", "Northwest Passage"),
                EBMLBuilder.simpleTag("DIRECTOR", "David Lynch"),
                EBMLBuilder.simpleTag("DATE_RELEASED", "1990-04-08"),
                EBMLBuilder.simpleTag("GENRE", "Mystery"),
                EBMLBuilder.simpleTag("PART_NUMBER", "1"),
            ]),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let tags = try MatroskaReader().read(url).tags
        #expect(tags.title == "Northwest Passage")
        #expect(tags[.director] == .string("David Lynch"))
        #expect(tags[.year] == .number(1990))
        #expect(tags.genre == "Mystery")
        #expect(tags[.episodeNumber] == .number(1))
    }

    @Test("target level decides whether a tag is about the series or the episode")
    func targetLevels() async throws {
        let url = try makeTestMKV(tags: [
            EBMLBuilder.tag(targetType: 70, [EBMLBuilder.simpleTag("TITLE", "Twin Peaks")]),
            EBMLBuilder.tag(targetType: 60, [EBMLBuilder.simpleTag("PART_NUMBER", "1")]),
            EBMLBuilder.tag(targetType: 50, [
                EBMLBuilder.simpleTag("TITLE", "Northwest Passage"),
                EBMLBuilder.simpleTag("PART_NUMBER", "1"),
            ]),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let tags = try MatroskaReader().read(url).tags
        #expect(tags[.showName] == .string("Twin Peaks"))
        #expect(tags[.seasonNumber] == .number(1))
        #expect(tags[.episodeNumber] == .number(1))
        #expect(tags.title == "Northwest Passage")
    }

    @Test("ignores per-track statistics tags mkvmerge writes")
    func ignoresTrackTags() async throws {
        let url = try makeTestMKV(tags: [
            EBMLBuilder.tag(targetType: 50, [EBMLBuilder.simpleTag("TITLE", "Northwest Passage")]),
            EBMLBuilder.tag(targetType: nil, trackUID: 1, [
                EBMLBuilder.simpleTag("BPS", "53"),
                EBMLBuilder.simpleTag("NUMBER_OF_FRAMES", "1057"),
                EBMLBuilder.simpleTag("_STATISTICS_TAGS", "BPS DURATION"),
            ]),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let tags = try MatroskaReader().read(url).tags
        #expect(tags.title == "Northwest Passage")
        #expect(tags[.custom("mkv/BPS")] == nil)
        #expect(tags[.custom("mkv/NUMBER_OF_FRAMES")] == nil)
    }

    @Test("numbers untitled chapters rather than calling them all \"Chapter\"")
    func numbersUntitledChapters() async throws {
        let url = try makeTestMKV(chapters: [
            EBMLBuilder.element(0xB6, EBMLBuilder.uint(0x91, 0)),
            EBMLBuilder.element(0xB6, EBMLBuilder.uint(0x91, 600_000_000_000)),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let chapters = try MatroskaReader().read(url).chapters
        #expect(chapters.map(\.title) == ["Chapter 1", "Chapter 2"])
    }

    @Test("reads chapters with titles and nanosecond starts")
    func readsChapters() async throws {
        let url = try makeTestMKV(chapters: [
            EBMLBuilder.chapter(start: 0, title: "Cold Open"),
            EBMLBuilder.chapter(start: 90_000_000_000, title: "Main Titles"),
            EBMLBuilder.chapter(start: 240_000_000_000, title: "Wrapped in Plastic"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let chapters = try MatroskaReader().read(url).chapters
        #expect(chapters.count == 3)
        #expect(chapters[0].title == "Cold Open")
        #expect(chapters[1].start == 90)
        #expect(chapters[2].title == "Wrapped in Plastic")
    }

    @Test("rejects a file that is not Matroska rather than guessing")
    func rejectsNonMatroska() throws {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mkv")
        try Data("this is not EBML".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: TagIOError.self) { try MatroskaReader().read(url) }
    }
}

@Suite("Real mkv", .enabled(if: TwinPeaks.realMediaRoot != nil))
struct RealMatroskaTests {
    @Test("reads the developer's own mkv files")
    func readsRealFiles() async throws {
        let root = try #require(TwinPeaks.realMediaRoot)
        let files = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "mkv" }
        #expect(!files.isEmpty, "no mkv files in \(root.path)")

        for url in files {
            let item = try MatroskaReader().read(url)
            #expect(item.duration ?? 0 > 60, "\(url.lastPathComponent): implausible duration")
        }
    }
}
