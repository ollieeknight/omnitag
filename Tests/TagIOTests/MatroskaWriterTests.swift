import Foundation
import MediaCore
import Testing
@testable import TagIO

/// Builds mkv files whose top-level layout we control, because the interesting
/// cases are entirely about layout: does the new Tags element fit where the old
/// one was, and what is next to it.
private func makeLayoutMKV(
    tags: [[UInt8]] = [],
    voidAfterTags: Int = 0,
    clusterBytes: Int = 4096,
    tagsAtEnd: Bool = false,
    seekHead: Bool = false
) throws -> URL {
    let header = EBMLBuilder.element(0x1A45DFA3, EBMLBuilder.string(0x4282, "matroska"))
    let info = EBMLBuilder.element(0x1549A966,
        EBMLBuilder.uint(0x2AD7B1, 1_000_000)
        + EBMLBuilder.double(0x4489, 5400 * 1000)
        + EBMLBuilder.string(0x7BA9, "Northwest Passage"))
    let cluster = EBMLBuilder.element(0x1F43B675, [UInt8](repeating: 0x42, count: clusterBytes))
    let tagsElement = tags.isEmpty ? [] : EBMLBuilder.element(0x1254C367, tags.flatMap { $0 })
    let padding = voidAfterTags > 0 ? (EBMLWriter.void(totalLength: voidAfterTags) ?? []) : []

    var body = info
    if seekHead {
        // Real writers give SeekPosition a fixed 8-byte body so the value can be
        // rewritten later. The position is patched in once the file exists and
        // the true offset is known.
        body = EBMLBuilder.element(0x114D9B74,
            EBMLBuilder.element(0x4DBB,
                EBMLBuilder.element(0x53AB, [0x12, 0x54, 0xC3, 0x67])
                + EBMLBuilder.element(0x53AC, [UInt8](repeating: 0, count: 8)))) + body
    }
    body += tagsAtEnd ? cluster + tagsElement + padding : tagsElement + padding + cluster

    let file = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mkv")
    try Data(header + EBMLBuilder.element(0x18538067, body)).write(to: file)

    if seekHead {
        let layout = try structure(of: file)
        if let tags = layout.tagsElements.first {
            try patchSeekPosition(in: file, to: tags.offset - layout.segmentBodyStart)
        }
    }
    return file
}

/// Overwrites the 8-byte SeekPosition payload, found by its `53AC 88` header.
private func patchSeekPosition(in url: URL, to position: Int) throws {
    var data = try Data(contentsOf: url)
    let marker: [UInt8] = [0x53, 0xAC, 0x88]
    guard let range = data.range(of: Data(marker)) else { return }
    let start = range.upperBound
    let bytes = (0..<8).reversed().map { UInt8((position >> (8 * $0)) & 0xFF) }
    data.replaceSubrange(start..<(start + 8), with: bytes)
    try data.write(to: url)
}

/// Every cluster byte in the file, so a test can prove the video was untouched.
private func clusterPayload(of url: URL) throws -> [Data] {
    let data = try Data(contentsOf: url)
    var reader = EBMLReader(data)
    _ = try reader.readElementID(); let headerSize = try reader.readSize()
    reader.skip(Int(headerSize ?? 0))
    _ = try reader.readElementID(); _ = try reader.readSize()

    var payloads: [Data] = []
    while !reader.isAtEnd {
        guard let id = try? reader.readElementID(), let size = try? reader.readSize() else { break }
        let length = Int(size ?? 0)
        if id == 0x1F43B675, let body = reader.readData(length: length) {
            payloads.append(body)
        } else {
            reader.skip(length)
        }
    }
    return payloads
}

/// Top-level element ids with their offsets, plus what the Segment header
/// claims its own size is. Structural checks a lenient reader would not make —
/// and a player would.
private struct Structure {
    var elements: [(id: UInt64, offset: Int, totalLength: Int)]
    var segmentBodyStart: Int
    var declaredSegmentSize: Int?
    var fileLength: Int

    var tagsElements: [(id: UInt64, offset: Int, totalLength: Int)] {
        elements.filter { $0.id == 0x1254C367 }
    }

    /// The Segment must declare exactly the bytes that follow it.
    var segmentSizeIsCorrect: Bool {
        declaredSegmentSize.map { $0 == fileLength - segmentBodyStart } ?? true
    }
}

private func structure(of url: URL) throws -> Structure {
    let data = try Data(contentsOf: url)
    var reader = EBMLReader(data)
    _ = try reader.readElementID()
    let headerSize = try reader.readSize()
    reader.skip(Int(headerSize ?? 0))
    _ = try reader.readElementID()
    let declared = try reader.readSize()
    let bodyStart = reader.offset

    var elements: [(UInt64, Int, Int)] = []
    while !reader.isAtEnd {
        let start = reader.offset
        guard let id = try? reader.readElementID(), let size = try? reader.readSize() else { break }
        let body = Int(size ?? 0)
        elements.append((id, start, reader.offset - start + body))
        reader.seek(to: reader.offset + body)
    }
    return Structure(
        elements: elements, segmentBodyStart: bodyStart,
        declaredSegmentSize: declared.map(Int.init), fileLength: data.count)
}

@Suite("MatroskaTagWriter")
struct MatroskaWriterTests {
    private func tagSet(_ pairs: [(TagKey, TagValue)]) -> TagSet {
        var tags = TagSet()
        for (key, value) in pairs { tags[key] = value }
        return tags
    }

    @Test("writes tags into a file that had none")
    func writesFirstTags() async throws {
        let url = try makeLayoutMKV()
        defer { try? FileManager.default.removeItem(at: url) }

        try await MatroskaTagWriter().write(
            tagSet([(.title, .string("Northwest Passage")), (.director, .string("David Lynch"))]),
            to: url)

        let read = try MatroskaReader().read(url)
        #expect(read.tags.title == "Northwest Passage")
        #expect(read.tags[.director] == .string("David Lynch"))

        let layout = try structure(of: url)
        #expect(layout.tagsElements.count == 1)
        #expect(layout.segmentSizeIsCorrect, "an appended element must be inside the Segment")
    }

    @Test("a smaller tag set is written in place, with the slack turned into padding")
    func shrinksInPlace() async throws {
        let url = try makeLayoutMKV(tags: [
            EBMLBuilder.tag(targetType: 50, [
                EBMLBuilder.simpleTag("TITLE", String(repeating: "Long title. ", count: 20)),
                EBMLBuilder.simpleTag("DIRECTOR", "David Lynch"),
            ]),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let sizeBefore = try Data(contentsOf: url).count
        let clustersBefore = try clusterPayload(of: url)

        try await MatroskaTagWriter().write(tagSet([(.title, .string("Short"))]), to: url)

        #expect(try Data(contentsOf: url).count == sizeBefore, "in-place: file size must not change")
        #expect(try clusterPayload(of: url) == clustersBefore, "video must be untouched")
        #expect(try structure(of: url).segmentSizeIsCorrect)
        #expect(try MatroskaReader().read(url).tags.title == "Short")
    }

    @Test("a bigger tag set grows into the Void that follows it")
    func growsIntoAdjacentVoid() async throws {
        let url = try makeLayoutMKV(
            tags: [EBMLBuilder.tag(targetType: 50, [EBMLBuilder.simpleTag("TITLE", "Short")])],
            voidAfterTags: 2048)
        defer { try? FileManager.default.removeItem(at: url) }
        let sizeBefore = try Data(contentsOf: url).count
        let clustersBefore = try clusterPayload(of: url)

        let long = String(repeating: "Wrapped in plastic. ", count: 40)
        try await MatroskaTagWriter().write(
            tagSet([(.title, .string(long)), (.synopsis, .string(long))]), to: url)

        #expect(try Data(contentsOf: url).count == sizeBefore, "the Void absorbs the growth")
        #expect(try clusterPayload(of: url) == clustersBefore)
        #expect(try MatroskaReader().read(url).tags.title == long)
    }

    @Test("when there is no room, the old element becomes padding and the new one is appended")
    func relocatesWhenItCannotFit() async throws {
        let url = try makeLayoutMKV(
            tags: [EBMLBuilder.tag(targetType: 50, [EBMLBuilder.simpleTag("TITLE", "Short")])])
        defer { try? FileManager.default.removeItem(at: url) }
        let clustersBefore = try clusterPayload(of: url)

        let long = String(repeating: "Wrapped in plastic. ", count: 60)
        try await MatroskaTagWriter().write(tagSet([(.title, .string(long))]), to: url)

        let read = try MatroskaReader().read(url)
        #expect(read.tags.title == long, "only the new element may be found")
        #expect(try clusterPayload(of: url) == clustersBefore, "video must be untouched")
        #expect(read.duration ?? 0 > 0, "the file must still parse end to end")

        let layout = try structure(of: url)
        #expect(layout.tagsElements.count == 1, "the old element must have become padding")
        #expect(layout.segmentSizeIsCorrect, "the Segment must declare the bytes it now contains")
    }

    @Test("tags at the end of the file grow by extending the file")
    func growsAtEndOfFile() async throws {
        let url = try makeLayoutMKV(
            tags: [EBMLBuilder.tag(targetType: 50, [EBMLBuilder.simpleTag("TITLE", "Short")])],
            tagsAtEnd: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let clustersBefore = try clusterPayload(of: url)

        let long = String(repeating: "Twin Peaks. ", count: 50)
        try await MatroskaTagWriter().write(tagSet([(.title, .string(long))]), to: url)

        #expect(try MatroskaReader().read(url).tags.title == long)
        #expect(try clusterPayload(of: url) == clustersBefore)

        let layout = try structure(of: url)
        #expect(layout.tagsElements.count == 1)
        #expect(layout.segmentSizeIsCorrect, "growing at the end must update the Segment size")
    }

    @Test("the file is patched, never rewritten — the inode survives")
    func patchesInPlace() async throws {
        let url = try makeLayoutMKV(
            tags: [EBMLBuilder.tag(targetType: 50, [EBMLBuilder.simpleTag("TITLE", "Short")])],
            voidAfterTags: 2048)
        defer { try? FileManager.default.removeItem(at: url) }
        let inodeBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int

        try await MatroskaTagWriter().write(tagSet([(.title, .string("Northwest Passage"))]), to: url)

        let inodeAfter = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        #expect(inodeAfter == inodeBefore, "a temp-file swap would change the inode")
    }

    @Test("target levels are written back the way they are read")
    func writesTargetLevels() async throws {
        let url = try makeLayoutMKV(voidAfterTags: 0)
        defer { try? FileManager.default.removeItem(at: url) }

        try await MatroskaTagWriter().write(tagSet([
            (.showName, .string("Twin Peaks")),
            (.seasonNumber, .number(1)),
            (.episodeNumber, .number(1)),
            (.title, .string("Northwest Passage")),
            (.year, .number(1990)),
        ]), to: url)

        let tags = try MatroskaReader().read(url).tags
        #expect(tags[.showName] == .string("Twin Peaks"))
        #expect(tags[.seasonNumber] == .number(1))
        #expect(tags[.episodeNumber] == .number(1))
        #expect(tags.title == "Northwest Passage")
        #expect(tags[.year] == .number(1990))
    }

    @Test("a stale SeekHead entry is repaired when the element moves")
    func repairsSeekHead() async throws {
        let url = try makeLayoutMKV(
            tags: [EBMLBuilder.tag(targetType: 50, [EBMLBuilder.simpleTag("TITLE", "Short")])],
            seekHead: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let long = String(repeating: "Wrapped in plastic. ", count: 60)
        try await MatroskaTagWriter().write(tagSet([(.title, .string(long))]), to: url)

        let data = try Data(contentsOf: url)
        let layout = try structure(of: url)
        let tags = try #require(layout.tagsElements.first)
        let position = try #require(try seekPosition(forTagsIn: data) ?? nil)

        #expect(position == tags.offset - layout.segmentBodyStart,
                "the SeekHead must point at where Tags actually moved to")
        var reader = EBMLReader(data, offset: layout.segmentBodyStart + position)
        #expect(try reader.readElementID() == 0x1254C367)
        #expect(try MatroskaReader().read(url).tags.title == long)
    }

    @Test("refuses a file that is not Matroska")
    func refusesNonMatroska() async throws {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mkv")
        try Data("not EBML at all".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: TagIOError.self) {
            try await MatroskaTagWriter().write(TagSet(), to: url)
        }
    }

    @Test("a file that cannot be opened for writing is refused, unchanged")
    func refusesUnwritableFile() async throws {
        let url = try makeLayoutMKV()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)

        await #expect(throws: TagIOError.self) {
            try await MatroskaTagWriter().write(TagSet([.title: .string("After")]), to: url)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    // MARK: helpers

    private func segmentStart(_ data: Data) -> Int {
        var reader = EBMLReader(data)
        _ = try? reader.readElementID()
        let headerSize = (try? reader.readSize()) ?? 0
        reader.skip(Int(headerSize ?? 0))
        _ = try? reader.readElementID()
        _ = try? reader.readSize()
        return reader.offset
    }

    /// The position the SeekHead claims Tags lives at, if it has such an entry.
    private func seekPosition(forTagsIn data: Data) throws -> Int?? {
        var reader = EBMLReader(data, offset: segmentStart(data))
        while !reader.isAtEnd {
            guard let id = try? reader.readElementID(), let size = try? reader.readSize() else { break }
            let end = reader.offset + Int(size ?? 0)
            guard id == 0x114D9B74 else { reader.seek(to: end); continue }

            while reader.offset < end {
                guard let seekID = try? reader.readElementID(),
                      let seekSize = try? reader.readSize() else { break }
                let seekEnd = reader.offset + Int(seekSize ?? 0)
                if seekID == 0x4DBB {
                    var isTags = false
                    var position: Int?
                    while reader.offset < seekEnd {
                        guard let fieldID = try? reader.readElementID(),
                              let fieldSize = try? reader.readSize() else { break }
                        let length = Int(fieldSize ?? 0)
                        if fieldID == 0x53AB, let bytes = reader.readData(length: length) {
                            isTags = [UInt8](bytes) == [0x12, 0x54, 0xC3, 0x67]
                        } else if fieldID == 0x53AC, let value = reader.readUInt(length: length) {
                            position = Int(value)
                        } else {
                            reader.skip(length)
                        }
                    }
                    if isTags { return position }
                }
                reader.seek(to: seekEnd)
            }
            reader.seek(to: end)
        }
        return nil
    }
}

@Suite("Real mkv writing", .enabled(if: TwinPeaks.realMediaRoot != nil))
struct RealMatroskaWriteTests {
    /// Works on copies. Both real files exercise a different branch: the episode
    /// has Tags as the last element, the film has Clusters immediately after.
    @Test("edits both real mkv files without touching their video")
    func writesRealFiles() async throws {
        let root = try #require(TwinPeaks.realMediaRoot)
        let files = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "mkv" }

        for source in files {
            let copy = URL.temporaryDirectory.appending(path: "copy-\(UUID().uuidString).mkv")
            try FileManager.default.copyItem(at: source, to: copy)
            defer { try? FileManager.default.removeItem(at: copy) }

            let before = try MatroskaReader().read(copy)
            var edited = before.tags
            edited[.showName] = .string("Twin Peaks")
            edited[.director] = .string("David Lynch")
            try await MatroskaTagWriter().write(edited, to: copy)

            let after = try MatroskaReader().read(copy)
            #expect(after.tags[.showName] == .string("Twin Peaks"))
            #expect(after.tags[.director] == .string("David Lynch"))
            #expect(after.chapters.count == before.chapters.count, "chapters must survive")
            let drift = abs((after.duration ?? 0) - (before.duration ?? 0))
            #expect(drift < 0.001, "\(source.lastPathComponent): duration changed by \(drift)")
        }
    }
}
