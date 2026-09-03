import Foundation
@testable import LibraryIndex
import MediaCore
import Testing

@Suite("LibraryScanner")
struct ScannerTests {
    /// Builds a throwaway tree of empty files with real extensions.
    private func fixture(_ names: [String]) throws -> URL {
        let root = URL.temporaryDirectory.appending(path: "scan-\(UUID().uuidString)")
        for name in names {
            let file = root.appending(path: name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data().write(to: file)
        }
        return root
    }

    @Test("finds media recursively and skips everything else")
    func findsMedia() async throws {
        let root = try fixture([
            "Music/a.mp3", "Music/nested/b.flac", "Books/c.m4b",
            "notes.txt", ".hidden/d.mp3", "Movies/e.mkv"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let found = try await LibraryScanner().scan(root)
        let names = Set(found.map(\.url.lastPathComponent))
        #expect(names == ["a.mp3", "b.flac", "c.m4b", "e.mkv"])
    }

    @Test("assigns a default kind per container")
    func assignsKind() async throws {
        let root = try fixture(["a.mp3", "b.m4b", "c.mp4"])
        defer { try? FileManager.default.removeItem(at: root) }

        let byName = try await LibraryScanner().scan(root)
            .reduce(into: [String: MediaKind]()) { $0[$1.url.lastPathComponent] = $1.kind }
        #expect(byName["a.mp3"] == .music)
        #expect(byName["b.m4b"] == .audiobook)
        #expect(byName["c.mp4"] == .movie)
    }

    @Test("missing directory throws rather than returning empty")
    func missingDirectory() async {
        await #expect(throws: (any Error).self) {
            try await LibraryScanner().scan(URL(filePath: "/nope/definitely/not/here"))
        }
    }
}
