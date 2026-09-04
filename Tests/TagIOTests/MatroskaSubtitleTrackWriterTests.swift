import Foundation
import MediaCore
@testable import TagIO
import Testing

@Suite("MatroskaTagWriter subtitle tracks")
struct MatroskaSubtitleTrackWriterTests {
    /// `patchTracks` is pure byte surgery: given a Tracks element's raw body
    /// and edits keyed by trackUID, it must preserve every byte of every
    /// TrackEntry it isn't asked to change — video, audio, unmatched
    /// subtitle tracks, and any field within a matched TrackEntry that isn't
    /// one of the six known editable fields (e.g. CodecPrivate).
    @Test("untouched TrackEntries — video, audio, an unedited subtitle track — survive byte-for-byte")
    func patchTracksLeavesUntouchedEntriesAlone() {
        let video = EBMLBuilder.trackEntry(uid: 1, type: 1, codecID: "V_MPEGH/ISO/HEVC")
        let audio = EBMLBuilder.trackEntry(uid: 2, type: 2, codecID: "A_AAC")
        let subtitle = EBMLBuilder.trackEntry(uid: 3, type: 17, codecID: "S_TEXT/UTF8", language: "eng")
        let body = video + audio + subtitle

        let patched = MatroskaTagWriter.patchTracks(body, edits: [:])
        #expect(patched == body)
    }

    @Test("a matched subtitle track's known fields are replaced, unknown fields survive")
    func patchTracksReplacesKnownFieldsOnly() throws {
        let codecPrivate = EBMLBuilder.element(0x63A2, [0xDE, 0xAD, 0xBE, 0xEF])
        let subtitle = EBMLBuilder.trackEntry(
            uid: 3, type: 17, codecID: "S_TEXT/ASS", language: "eng", name: "Old Name", extra: codecPrivate
        )

        let patched = MatroskaTagWriter.patchTracks(subtitle, edits: [
            3: SubtitleTrack(trackUID: 3, codecID: "S_TEXT/ASS", language: "fre", name: "New Name")
        ])

        var reader = EBMLReader(Data(patched))
        _ = try reader.readElementID() // TrackEntry
        let size = try #require(try reader.readSize())
        let entryEnd = reader.offset + Int(size)

        var sawCodecPrivate = false
        var language: String?
        var name: String?
        while reader.offset < entryEnd {
            let id = try reader.readElementID()
            let fieldSize = try #require(try reader.readSize())
            let fieldEnd = reader.offset + Int(fieldSize)
            switch id {
            case 0x63A2: sawCodecPrivate = reader.readData(length: Int(fieldSize)) == Data([0xDE, 0xAD, 0xBE, 0xEF])
            case 0x22B59D: language = reader.readString(length: Int(fieldSize))
            case 0x536E: name = reader.readString(length: Int(fieldSize))
            default: break
            }
            reader.seek(to: fieldEnd)
        }
        #expect(sawCodecPrivate, "CodecPrivate must survive untouched")
        #expect(language == "fre")
        #expect(name == "New Name")
    }

    @Test("an edit with no matching trackUID in the file is silently ignored, never inserted as a phantom track")
    func patchTracksIgnoresUnmatchedEdit() {
        let subtitle = EBMLBuilder.trackEntry(uid: 3, type: 17, codecID: "S_TEXT/UTF8")

        let patched = MatroskaTagWriter.patchTracks(subtitle, edits: [
            99: SubtitleTrack(trackUID: 99, codecID: "S_TEXT/UTF8", language: "fre")
        ])

        #expect(patched == subtitle)
    }

    @Test("full round trip: writing subtitle track edits through MatroskaTagWriter")
    func writesSubtitleTracksEndToEnd() async throws {
        let url = try makeTestMKVForWriter(trackEntries: [
            EBMLBuilder.trackEntry(uid: 1, type: 1, codecID: "V_MPEGH/ISO/HEVC"),
            EBMLBuilder.trackEntry(uid: 2, type: 17, codecID: "S_TEXT/UTF8")
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let clustersBefore = try clusterPayload(of: url)

        try await MatroskaTagWriter().write(TagSet(), subtitleTracks: [
            SubtitleTrack(trackUID: 2, codecID: "S_TEXT/UTF8", language: "eng", name: "English", isDefault: true)
        ], to: url)

        let read = try MatroskaReader().read(url)
        #expect(read.subtitleTracks.count == 1)
        #expect(read.subtitleTracks[0].language == "eng")
        #expect(read.subtitleTracks[0].name == "English")
        #expect(read.subtitleTracks[0].isDefault)
        #expect(try clusterPayload(of: url) == clustersBefore, "video must be untouched")
        #expect(try structure(of: url).segmentSizeIsCorrect)
    }

    @Test("nil subtitleTracks argument leaves existing tracks untouched")
    func nilSubtitleTracksIsANoOp() async throws {
        let url = try makeTestMKVForWriter(trackEntries: [
            EBMLBuilder.trackEntry(uid: 1, type: 17, codecID: "S_TEXT/UTF8", language: "eng")
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        try await MatroskaTagWriter().write(TagSet([.title: .string("Northwest Passage")]), to: url)

        let read = try MatroskaReader().read(url)
        #expect(read.subtitleTracks[0].language == "eng")
        #expect(read.tags.title == "Northwest Passage")
    }

    /// Same shape as `MatroskaWriterTests`'s `makeLayoutMKV` but with a Tracks
    /// element, for tests that need to patch a real TrackEntry.
    private func makeTestMKVForWriter(trackEntries: [[UInt8]]) throws -> URL {
        let header = EBMLBuilder.element(0x1A45_DFA3, EBMLBuilder.string(0x4282, "matroska"))
        let info = EBMLBuilder.element(0x1549_A966,
                                       EBMLBuilder.uint(0x2AD7B1, 1_000_000)
                                           + EBMLBuilder.double(0x4489, 5400 * 1000))
        let tracks = EBMLBuilder.tracks(trackEntries)
        let cluster = EBMLBuilder.element(0x1F43_B675, [UInt8](repeating: 0x42, count: 4096))
        let body = info + tracks + cluster
        let file = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mkv")
        try Data(header + EBMLBuilder.element(0x1853_8067, body)).write(to: file)
        return file
    }

    /// Every cluster byte in the file, so a test can prove the video was untouched.
    private func clusterPayload(of url: URL) throws -> [Data] {
        let data = try Data(contentsOf: url)
        var reader = EBMLReader(data)
        _ = try reader.readElementID()
        let headerSize = try reader.readSize()
        reader.skip(Int(headerSize ?? 0))
        _ = try reader.readElementID()
        _ = try reader.readSize()

        var payloads: [Data] = []
        while !reader.isAtEnd {
            guard let id = try? reader.readElementID(), let size = try? reader.readSize() else { break }
            let length = Int(size ?? 0)
            if id == 0x1F43_B675, let body = reader.readData(length: length) {
                payloads.append(body)
            } else {
                reader.skip(length)
            }
        }
        return payloads
    }

    private struct Structure {
        var elements: [(id: UInt64, offset: Int, totalLength: Int)]
        var segmentBodyStart: Int
        var declaredSegmentSize: Int?
        var fileLength: Int

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
            declaredSegmentSize: declared.map(Int.init), fileLength: data.count
        )
    }
}
