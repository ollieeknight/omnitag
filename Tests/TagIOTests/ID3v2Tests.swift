import Foundation
import MediaCore
import Testing
@testable import TagIO

@Suite("Synchsafe integers")
struct SynchsafeTests {
    @Test("round-trips values either side of the 7-bit boundary",
          arguments: [0, 1, 127, 128, 255, 256, 1024, 65_535, 268_435_455] as [Int])
    func roundTrip(value: Int) throws {
        let encoded = ID3v2.synchsafe(value)
        #expect(encoded.count == 4)
        #expect(encoded.allSatisfy { $0 < 0x80 }, "no byte may have its high bit set")
        #expect(ID3v2.desynchsafe(encoded) == value)
    }

    @Test("matches the encoding real files use")
    func knownEncoding() {
        // 257 = 0b1_0000_0001 -> 7-bit groups 0000010 0000001
        #expect(ID3v2.synchsafe(257) == [0x00, 0x00, 0x02, 0x01])
        #expect(ID3v2.desynchsafe([0x00, 0x00, 0x02, 0x01]) == 257)
    }

    @Test("plain big-endian sizes are read differently — the v2.3 trap")
    func plainSizes() {
        #expect(ID3v2.bigEndian([0x00, 0x00, 0x02, 0x01]) == 513)
    }
}

/// Hand-built ID3 tags: the parser is tested against bytes we control.
enum ID3Builder {
    static func frame(_ id: String, payload: [UInt8], synchsafeSize: Bool = true) -> [UInt8] {
        let size = synchsafeSize
            ? ID3v2.synchsafe(payload.count)
            : withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Array($0) }
        return Array(id.utf8) + size + [0x00, 0x00] + payload
    }

    /// A UTF-8 text frame: encoding byte 0x03, then the string.
    static func text(_ id: String, _ value: String, synchsafeSize: Bool = true) -> [UInt8] {
        frame(id, payload: [0x03] + Array(value.utf8), synchsafeSize: synchsafeSize)
    }

    static func tag(version: UInt8 = 4, flags: UInt8 = 0, frames: [[UInt8]], padding: Int = 0) -> [UInt8] {
        let body = frames.flatMap { $0 } + [UInt8](repeating: 0, count: padding)
        return Array("ID3".utf8) + [version, 0x00, flags] + ID3v2.synchsafe(body.count) + body
    }

    /// Tag plus stand-in audio. Not decodable — no macOS mp3 encoder exists —
    /// but the writer must never look at these bytes, only preserve them.
    static func mp3(tag: [UInt8], audio: [UInt8] = [0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0x55, count: 512)) -> URL {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mp3")
        try? Data(tag + audio).write(to: url)
        return url
    }
}

@Suite("ID3v2 tag parsing")
struct ID3v2ParseTests {
    @Test("reads frames out of a v2.4 tag")
    func parsesFrames() throws {
        let bytes = ID3Builder.tag(frames: [
            ID3Builder.text("TIT2", "Twin Peaks Theme"),
            ID3Builder.text("TPE1", "Angelo Badalamenti"),
        ])
        let tag = try #require(ID3v2.parse(Data(bytes)))
        #expect(tag.frames.map(\.id) == ["TIT2", "TPE1"])
        #expect(tag.frames[0].textValue == "Twin Peaks Theme")
        #expect(tag.totalSize == bytes.count)
    }

    @Test("reads v2.3 frames, whose sizes are plain big-endian")
    func parsesVersion3() throws {
        let bytes = ID3Builder.tag(version: 3, frames: [
            ID3Builder.text("TIT2", "Twin Peaks Theme", synchsafeSize: false),
            ID3Builder.text("TYER", "1990", synchsafeSize: false),
        ])
        let tag = try #require(ID3v2.parse(Data(bytes)))
        #expect(tag.version == 3)
        #expect(tag.frames.map(\.id) == ["TIT2", "TYER"])
        #expect(tag.frames[1].textValue == "1990")
    }

    @Test("reads a v2.3 frame longer than 127 bytes, where the two size encodings diverge")
    func parsesLargeVersion3Frame() throws {
        // Below 128 both encodings agree, so a short fixture proves nothing.
        let long = String(repeating: "Wrapped in plastic. ", count: 20)
        let bytes = ID3Builder.tag(version: 3, frames: [
            ID3Builder.text("COMM", long, synchsafeSize: false),
            ID3Builder.text("TIT2", "Northwest Passage", synchsafeSize: false),
        ])
        let tag = try #require(ID3v2.parse(Data(bytes)))
        #expect(tag.frames.map(\.id) == ["COMM", "TIT2"], "misread sizes shift every later frame")
        #expect(tag.frames[1].textValue == "Northwest Passage")
    }

    @Test("stops at padding rather than inventing frames from zero bytes")
    func stopsAtPadding() throws {
        let bytes = ID3Builder.tag(frames: [ID3Builder.text("TIT2", "Only One")], padding: 64)
        let tag = try #require(ID3v2.parse(Data(bytes)))
        #expect(tag.frames.count == 1)
    }

    @Test("returns nil for a file with no tag at all")
    func noTag() {
        #expect(ID3v2.parse(Data([0xFF, 0xFB, 0x90, 0x00])) == nil)
    }

    @Test("decodes the text encodings real files use", arguments: [
        ([0x00] + Array("Laura".utf8), "Laura"),            // ISO-8859-1
        ([0x03] + Array("Laura".utf8), "Laura"),            // UTF-8
        ([0x01, 0xFF, 0xFE, 0x4C, 0x00, 0x61, 0x00], "La"), // UTF-16 with BOM
    ] as [([UInt8], String)])
    func decodesEncodings(payload: [UInt8], expected: String) {
        let frame = ID3v2.Frame(id: "TIT2", flags: [0, 0], payload: Data(payload))
        #expect(frame.textValue == expected)
    }
}

@Suite("ID3TagWriter")
struct ID3TagWriterTests {
    private func read(_ url: URL) throws -> ID3v2.Tag {
        try #require(ID3v2.parse(try Data(contentsOf: url)))
    }

    @Test("writes the managed keys as v2.4 frames")
    func writesTags() async throws {
        let url = ID3Builder.mp3(tag: ID3Builder.tag(frames: []))
        defer { try? FileManager.default.removeItem(at: url) }

        var tags = TagSet()
        tags.title = "Twin Peaks Theme"
        tags.artist = "Angelo Badalamenti"
        tags.album = "Twin Peaks"
        tags[.year] = .number(1990)
        tags[.trackNumber] = .number(1)
        tags[.trackTotal] = .number(11)
        try await ID3TagWriter().write(tags, to: url)

        let written = try read(url)
        #expect(written.version == 4)
        #expect(written.frames.first { $0.id == "TIT2" }?.textValue == "Twin Peaks Theme")
        #expect(written.frames.first { $0.id == "TDRC" }?.textValue == "1990")
        #expect(written.frames.first { $0.id == "TRCK" }?.textValue == "1/11")
    }

    @Test("a written tag reads back through the normal reader path")
    func roundTripsThroughTagSet() async throws {
        let url = ID3Builder.mp3(tag: ID3Builder.tag(frames: []))
        defer { try? FileManager.default.removeItem(at: url) }

        var tags = TagSet()
        tags.title = "Twin Peaks Theme"
        tags.artist = "Angelo Badalamenti"
        tags[.year] = .number(1990)
        tags[.trackNumber] = .number(1)
        tags[.trackTotal] = .number(11)
        try await ID3TagWriter().write(tags, to: url)

        let readBack = try ID3v2.tagSet(from: read(url))
        #expect(readBack.title == "Twin Peaks Theme")
        #expect(readBack[.year] == .number(1990))
        #expect(readBack[.trackNumber] == .number(1))
        #expect(readBack[.trackTotal] == .number(11))
    }

    @Test("audio bytes are never touched")
    func preservesAudio() async throws {
        let audio = [0xFF, 0xFB, 0x90, 0x00] as [UInt8] + (0..<2048).map { UInt8($0 % 251) }
        let url = ID3Builder.mp3(tag: ID3Builder.tag(frames: [ID3Builder.text("TIT2", "Before")]),
                                 audio: audio)
        defer { try? FileManager.default.removeItem(at: url) }

        var tags = TagSet(); tags.title = "After"
        try await ID3TagWriter().write(tags, to: url)

        let data = try Data(contentsOf: url)
        let tag = try #require(ID3v2.parse(data))
        #expect(Array(data.dropFirst(tag.totalSize)) == audio)
    }

    @Test("frames we do not manage survive the write")
    func preservesUnknownFrames() async throws {
        let url = ID3Builder.mp3(tag: ID3Builder.tag(frames: [
            ID3Builder.text("TIT2", "Before"),
            ID3Builder.text("TMOO", "Ominous"),
            ID3Builder.frame("PRIV", payload: [0x01, 0x02, 0x03]),
        ]))
        defer { try? FileManager.default.removeItem(at: url) }

        var tags = TagSet(); tags.title = "After"
        try await ID3TagWriter().write(tags, to: url)

        let written = try read(url)
        #expect(written.frames.first { $0.id == "TMOO" }?.textValue == "Ominous")
        #expect(written.frames.first { $0.id == "PRIV" }?.payload == Data([0x01, 0x02, 0x03]))
        #expect(written.frames.first { $0.id == "TIT2" }?.textValue == "After")
    }

    @Test("a v2.3 year frame becomes its v2.4 equivalent instead of both existing")
    func upgradesYearFrame() async throws {
        let url = ID3Builder.mp3(tag: ID3Builder.tag(version: 3, frames: [
            ID3Builder.text("TYER", "1990", synchsafeSize: false),
        ]))
        defer { try? FileManager.default.removeItem(at: url) }

        var tags = TagSet(); tags[.year] = .number(1990)
        try await ID3TagWriter().write(tags, to: url)

        let written = try read(url)
        #expect(written.frames.contains { $0.id == "TDRC" })
        #expect(written.frames.contains { $0.id == "TYER" } == false)
    }

    @Test("clearing a field removes its frame rather than writing an empty one")
    func clearingRemovesFrame() async throws {
        let url = ID3Builder.mp3(tag: ID3Builder.tag(frames: [ID3Builder.text("TIT2", "Before")]))
        defer { try? FileManager.default.removeItem(at: url) }

        try await ID3TagWriter().write(TagSet(), to: url)
        #expect(try read(url).frames.contains { $0.id == "TIT2" } == false)
    }

    @Test("refuses tag layouts it cannot rewrite safely instead of losing frames",
          arguments: [
              (2 as UInt8, 0 as UInt8),     // v2.2: three-character frame ids
              (4, 0x80),                    // unsynchronised
          ])
    func refusesUnsupportedTags(version: UInt8, flags: UInt8) async throws {
        let url = ID3Builder.mp3(tag: ID3Builder.tag(version: version, flags: flags, frames: [
            ID3Builder.text("TIT2", "Before"),
        ]))
        defer { try? FileManager.default.removeItem(at: url) }

        var tags = TagSet(); tags.title = "After"
        await #expect(throws: TagIOError.self) { try await ID3TagWriter().write(tags, to: url) }
    }

    @Test("a failed write leaves the original byte-identical")
    func failedWriteIsAtomic() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "track.mp3")
        try Data(ID3Builder.tag(frames: [ID3Builder.text("TIT2", "Before")]) + [0xFF, 0xFB]).write(to: url)
        let original = try Data(contentsOf: url)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        var tags = TagSet(); tags.title = "After"
        await #expect(throws: (any Error).self) { try await ID3TagWriter().write(tags, to: url) }
        #expect(try Data(contentsOf: url) == original)
    }
}

@Suite("Real mp3 writing", .enabled(if: TwinPeaks.realMediaRoot != nil))
struct RealMP3WriteTests {
    /// Works on a copy: the developer's library is never written to by a test.
    @Test("edits a real mp3 and AVFoundation still reads it")
    func writesRealFile() async throws {
        let root = try #require(TwinPeaks.realMediaRoot)
        let source = try #require(try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.pathExtension.lowercased() == "mp3" })

        let copy = URL.temporaryDirectory.appending(path: "copy-\(UUID().uuidString).mp3")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let before = try await MediaTagReader().read(copy)
        var edited = before.tags
        edited.title = "Falling"
        try await ID3TagWriter().write(edited, to: copy)

        let after = try await MediaTagReader().read(copy)
        #expect(after.tags.title == "Falling")
        #expect(after.tags.artist == before.tags.artist, "other tags must survive")
        #expect(abs((after.duration ?? 0) - (before.duration ?? 0)) < 0.1, "audio must be intact")
    }
}
