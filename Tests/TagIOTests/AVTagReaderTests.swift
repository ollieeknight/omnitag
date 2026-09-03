import Foundation
import MediaCore
@testable import TagIO
import Testing

@Suite("AVTagReader", .serialized)
struct AVTagReaderTests {
    /// Real m4a on disk: 0.5s of silence via afconvert, tagged with a title.
    private func makeM4A(title: String) throws -> URL {
        let dir = URL.temporaryDirectory.appending(path: "tagio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appending(path: "src.wav")
        let m4a = dir.appending(path: "out.m4a")

        // 44.1kHz mono 16-bit silence, hand-built WAV header.
        let frames = 22050
        var data = Data()
        func le(_ v: UInt32) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        func le16(_ v: UInt16) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        le(UInt32(36 + frames * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        le(16)
        le16(1)
        le16(1)
        le(44100)
        le(88200)
        le16(2)
        le16(16)
        data.append(contentsOf: Array("data".utf8))
        le(UInt32(frames * 2))
        data.append(Data(count: frames * 2))
        try data.write(to: wav)

        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/afconvert")
        p.arguments = ["-f", "m4af", "-d", "aac", wav.path, m4a.path]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "afconvert failed")
        return m4a
    }

    @Test("reads duration and container from a real m4a")
    func readsRealFile() async throws {
        let url = try makeM4A(title: "Hello")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let item = try await AVTagReader().read(url)
        #expect(item.container == .m4a)
        #expect(item.duration ?? 0 > 0.4)
    }

    @Test("reports a helpful error for a file that is not media")
    func rejectsGarbage() async throws {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mp3")
        try Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: TagIOError.self) { try await AVTagReader().read(url) }
    }
}
