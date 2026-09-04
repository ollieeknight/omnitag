import Foundation
import MediaCore
@testable import TagIO
import Testing

/// Builds EBML by hand so the parser is tested against bytes we control, not
/// against whatever a muxer happened to emit. Small enough to read; that is the
/// point — a fixture you cannot read proves nothing.
enum EBMLBuilder {
    static func vint(_ value: UInt64) -> [UInt8] {
        for width in 1 ... 8 where value < (UInt64(1) << (7 * width)) - 1 {
            var bytes = [UInt8]()
            for index in (0 ..< width).reversed() {
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
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
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
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
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
        if let trackUID {
            targetBody += uint(0x63C5, trackUID)
        }
        let targets = targetBody.isEmpty ? [] : element(0x63C0, targetBody)
        return element(0x7373, targets + tags.flatMap(\.self))
    }

    static func chapter(start: UInt64, title: String) -> [UInt8] {
        element(0xB6, uint(0x91, start) + element(0x80, string(0x85, title)))
    }

    /// A TrackEntry. `type` follows Matroska's TrackType values: 1 = video,
    /// 2 = audio, 17 = subtitle.
    static func trackEntry(
        uid: UInt64, type: UInt64, codecID: String, language: String? = nil,
        languageBCP47: String? = nil, name: String? = nil,
        isDefault: Bool = false, isForced: Bool = false, isEnabled: Bool = true,
        extra: [UInt8] = []
    ) -> [UInt8] {
        var body = uint(0xD7, uid) // TrackNumber: any nonzero value the tests don't need distinct from uid
            + uint(0x73C5, uid)
            + uint(0x83, type)
            + string(0x86, codecID)
            + uint(0x88, isDefault ? 1 : 0)
            + uint(0x55AA, isForced ? 1 : 0)
            + uint(0xB9, isEnabled ? 1 : 0)
        if let language {
            body += string(0x22B59C, language)
        }
        if let languageBCP47 {
            body += string(0x22B59D, languageBCP47)
        }
        if let name {
            body += string(0x536E, name)
        }
        body += extra
        return element(0xAE, body)
    }

    static func tracks(_ entries: [[UInt8]]) -> [UInt8] {
        element(0x1654_AE6B, entries.flatMap(\.self))
    }
}

/// A synthetic Twin Peaks episode: enough Matroska to exercise every element
/// the reader cares about, none of the video.
func makeTestMKV(
    title: String = "Northwest Passage",
    duration: Double = 5400,
    tags: [[UInt8]] = [],
    chapters: [[UInt8]] = [],
    trackEntries: [[UInt8]] = []
) throws -> URL {
    let header = EBMLBuilder.element(0x1A45_DFA3, EBMLBuilder.string(0x4282, "matroska"))
    let info = EBMLBuilder.element(0x1549_A966,
                                   EBMLBuilder.uint(0x2AD7B1, 1_000_000) // TimestampScale: ms
                                       + EBMLBuilder.double(0x4489, duration * 1000) // Duration, in scale units
                                       + EBMLBuilder.string(0x7BA9, title))
    var segmentBody = info
    if !trackEntries.isEmpty {
        segmentBody += EBMLBuilder.tracks(trackEntries)
    }
    if !chapters.isEmpty {
        segmentBody += EBMLBuilder.element(0x1043_A770,
                                           EBMLBuilder.element(0x45B9, chapters.flatMap(\.self)))
    }
    if !tags.isEmpty {
        segmentBody += EBMLBuilder.element(0x1254_C367, tags.flatMap(\.self))
    }
    // A Cluster full of "frames" the reader must skip without reading.
    segmentBody += EBMLBuilder.element(0x1F43_B675, [UInt8](repeating: 0x42, count: 4096))

    let file = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mkv")
    try Data(header + EBMLBuilder.element(0x1853_8067, segmentBody)).write(to: file)
    return file
}

@Suite("MatroskaReader")
struct MatroskaTests {
    @Test("reads title and duration from the Info element")
    func readsInfo() throws {
        let url = try makeTestMKV(title: "Northwest Passage", duration: 5400)
        defer { try? FileManager.default.removeItem(at: url) }

        let item = try MatroskaReader().read(url)
        #expect(item.tags.title == "Northwest Passage")
        #expect(abs((item.duration ?? 0) - 5400) < 0.01)
        #expect(item.container == .mkv)
    }

    @Test("maps Matroska tag names onto the shared key set")
    func readsTags() throws {
        let url = try makeTestMKV(tags: [
            EBMLBuilder.tag(targetType: 50, [
                EBMLBuilder.simpleTag("TITLE", "Northwest Passage"),
                EBMLBuilder.simpleTag("DIRECTOR", "David Lynch"),
                EBMLBuilder.simpleTag("DATE_RELEASED", "1990-04-08"),
                EBMLBuilder.simpleTag("GENRE", "Mystery"),
                EBMLBuilder.simpleTag("PART_NUMBER", "1")
            ])
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
    func targetLevels() throws {
        let url = try makeTestMKV(tags: [
            EBMLBuilder.tag(targetType: 70, [EBMLBuilder.simpleTag("TITLE", "Twin Peaks")]),
            EBMLBuilder.tag(targetType: 60, [EBMLBuilder.simpleTag("PART_NUMBER", "1")]),
            EBMLBuilder.tag(targetType: 50, [
                EBMLBuilder.simpleTag("TITLE", "Northwest Passage"),
                EBMLBuilder.simpleTag("PART_NUMBER", "1")
            ])
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let tags = try MatroskaReader().read(url).tags
        #expect(tags[.showName] == .string("Twin Peaks"))
        #expect(tags[.seasonNumber] == .number(1))
        #expect(tags[.episodeNumber] == .number(1))
        #expect(tags.title == "Northwest Passage")
    }

    @Test("ignores per-track statistics tags mkvmerge writes")
    func ignoresTrackTags() throws {
        let url = try makeTestMKV(tags: [
            EBMLBuilder.tag(targetType: 50, [EBMLBuilder.simpleTag("TITLE", "Northwest Passage")]),
            EBMLBuilder.tag(targetType: nil, trackUID: 1, [
                EBMLBuilder.simpleTag("BPS", "53"),
                EBMLBuilder.simpleTag("NUMBER_OF_FRAMES", "1057"),
                EBMLBuilder.simpleTag("_STATISTICS_TAGS", "BPS DURATION")
            ])
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let tags = try MatroskaReader().read(url).tags
        #expect(tags.title == "Northwest Passage")
        #expect(tags[.custom("mkv/BPS")] == nil)
        #expect(tags[.custom("mkv/NUMBER_OF_FRAMES")] == nil)
    }

    @Test("numbers untitled chapters rather than calling them all \"Chapter\"")
    func numbersUntitledChapters() throws {
        let url = try makeTestMKV(chapters: [
            EBMLBuilder.element(0xB6, EBMLBuilder.uint(0x91, 0)),
            EBMLBuilder.element(0xB6, EBMLBuilder.uint(0x91, 600_000_000_000))
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let chapters = try MatroskaReader().read(url).chapters
        #expect(chapters.map(\.title) == ["Chapter 1", "Chapter 2"])
    }

    @Test("reads chapters with titles and nanosecond starts")
    func readsChapters() throws {
        let url = try makeTestMKV(chapters: [
            EBMLBuilder.chapter(start: 0, title: "Cold Open"),
            EBMLBuilder.chapter(start: 90_000_000_000, title: "Main Titles"),
            EBMLBuilder.chapter(start: 240_000_000_000, title: "Wrapped in Plastic")
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

    @Test("reads subtitle tracks, ignoring video and audio")
    func readsSubtitleTracks() throws {
        let url = try makeTestMKV(trackEntries: [
            EBMLBuilder.trackEntry(uid: 1, type: 1, codecID: "V_MPEGH/ISO/HEVC"),
            EBMLBuilder.trackEntry(uid: 2, type: 2, codecID: "A_AAC"),
            EBMLBuilder.trackEntry(uid: 3, type: 17, codecID: "S_TEXT/UTF8", language: "eng", name: "English")
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let tracks = try MatroskaReader().read(url).subtitleTracks
        #expect(tracks.count == 1)
        #expect(tracks[0].trackUID == 3)
        #expect(tracks[0].codecID == "S_TEXT/UTF8")
        #expect(tracks[0].language == "eng")
        #expect(tracks[0].name == "English")
    }

    @Test("LanguageBCP47 wins over the legacy Language field when both are present")
    func languageBCP47PreferredOverLegacy() throws {
        let url = try makeTestMKV(trackEntries: [
            EBMLBuilder.trackEntry(uid: 1, type: 17, codecID: "S_TEXT/UTF8", language: "eng", languageBCP47: "en-US")
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try MatroskaReader().read(url).subtitleTracks[0].language == "en-US")
    }

    @Test("reads default, forced and enabled flags")
    func readsSubtitleFlags() throws {
        let url = try makeTestMKV(trackEntries: [
            EBMLBuilder.trackEntry(
                uid: 1, type: 17, codecID: "S_TEXT/UTF8",
                isDefault: true, isForced: true, isEnabled: false
            )
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let track = try MatroskaReader().read(url).subtitleTracks[0]
        #expect(track.isDefault)
        #expect(track.isForced)
        #expect(track.isEnabled == false)
    }

    @Test("a track with no name has nil, not an empty string")
    func untitledSubtitleTrackHasNilName() throws {
        let url = try makeTestMKV(trackEntries: [
            EBMLBuilder.trackEntry(uid: 1, type: 17, codecID: "S_HDMV/PGS")
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try MatroskaReader().read(url).subtitleTracks[0].name == nil)
    }
}

@Suite("Real mkv", .enabled(if: TwinPeaks.realMediaRoot != nil))
struct RealMatroskaTests {
    @Test("reads the developer's own mkv files")
    func readsRealFiles() throws {
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

    @Test("reads subtitle tracks from a real muxer's output, not just synthetic fixtures")
    func readsRealSubtitleTracks() throws {
        let root = try #require(TwinPeaks.realMediaRoot)
        let episode = root.appending(path: "S01E01 - Northwest Passage.mkv")
        guard FileManager.default.fileExists(atPath: episode.path) else { return }

        let tracks = try MatroskaReader().read(episode).subtitleTracks
        #expect(!tracks.isEmpty, "the real episode file has an SRT track")
        #expect(tracks.allSatisfy { $0.codecID.hasPrefix("S_") })
    }

    @Test("reads a real film's mixed SRT and PGS (image-based) subtitle tracks")
    func readsRealMixedCodecSubtitleTracks() throws {
        let root = try #require(TwinPeaks.realMediaRoot)
        let film = root.appending(path: "Twin Peaks Fire Walk With Me (1992).mkv")
        guard FileManager.default.fileExists(atPath: film.path) else { return }

        let tracks = try MatroskaReader().read(film).subtitleTracks
        #expect(tracks.count == 4, "one SRT plus three PGS tracks")
        #expect(tracks.contains { $0.codecID == "S_TEXT/UTF8" && $0.language == "eng" })
        #expect(tracks.filter { $0.codecID == "S_HDMV/PGS" }.count == 3)
        #expect(Set(tracks.map(\.trackUID)).count == 4, "every track has a distinct identity")
    }

    /// The whole movie journey on a real 6.5 GB film: copy it, write the tags
    /// a TMDB movie record produces, read them back. This is the one test that
    /// exercises the video tag vocabulary against a real muxer's file rather
    /// than an `EBMLBuilder` fixture.
    @Test("writes and reads back a full movie tag set on a copy of the real film")
    func roundTripsAMovieTagSetOnTheRealFilm() async throws {
        let root = try #require(TwinPeaks.realMediaRoot)
        let film = root.appending(path: "Twin Peaks Fire Walk With Me (1992).mkv")
        guard FileManager.default.fileExists(atPath: film.path) else { return }

        let library = try FixtureLibrary()
        let copy = library.root.appending(path: film.lastPathComponent)
        try FileManager.default.copyItem(at: film, to: copy)

        var tags = TagSet()
        tags[.title] = .string("Twin Peaks: Fire Walk with Me")
        tags[.year] = .number(1992)
        tags[.director] = .string("David Lynch")
        tags[.studio] = .string("CIBY Pictures")
        tags[.genre] = .string("Crime/Drama/Mystery")
        tags[.contentRating] = .string("R")
        tags[.synopsis] = .string("The last seven days of Laura Palmer.")
        tags[.tmdbID] = .string("2667")

        try await MatroskaTagWriter().write(tags, to: copy)
        let item = try MatroskaReader().read(copy)

        for key in TagKey.standardFields(for: .movie).map(\.key) {
            #expect(item.tags[key] == tags[key], "\(key) did not round-trip")
        }
        // The film itself must still be intact — the writer patches outside
        // the Clusters, so the duration is the cheapest proof it did.
        #expect(item.duration ?? 0 > 60)
    }

    /// The TV half of the same journey, including the episode-shaped keys that
    /// Matroska stores at different target levels.
    @Test("writes and reads back a full episode tag set on a copy of the real episode")
    func roundTripsAnEpisodeTagSetOnTheRealFile() async throws {
        let root = try #require(TwinPeaks.realMediaRoot)
        let episode = root.appending(path: "S01E01 - Northwest Passage.mkv")
        guard FileManager.default.fileExists(atPath: episode.path) else { return }

        let library = try FixtureLibrary()
        let copy = library.root.appending(path: episode.lastPathComponent)
        try FileManager.default.copyItem(at: episode, to: copy)

        var tags = TagSet()
        tags[.title] = .string("Northwest Passage")
        tags[.showName] = .string("Twin Peaks")
        tags[.seasonNumber] = .number(1)
        tags[.episodeNumber] = .number(1)
        tags[.episodeTitle] = .string("Northwest Passage")
        tags[.year] = .number(1990)
        tags[.director] = .string("David Lynch")
        tags[.tmdbID] = .string("38713")

        try await MatroskaTagWriter().write(tags, to: copy)
        let item = try MatroskaReader().read(copy)

        for key in TagKey.standardFields(for: .tvEpisode).map(\.key) where tags[key] != nil {
            #expect(item.tags[key] == tags[key], "\(key) did not round-trip")
        }
        #expect(item.duration ?? 0 > 60)
    }
}
