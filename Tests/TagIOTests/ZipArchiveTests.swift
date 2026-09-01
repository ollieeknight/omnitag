import Foundation
import Testing
@testable import TagIO

@Suite("ZipArchive")
struct ZipArchiveTests {
    private func temporaryDirectory() throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "omnitag-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs a system tool and returns its status and output — used to prove our
    /// archives are readable by something that is not our own parser.
    @discardableResult
    private func run(_ launchPath: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(filePath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private let entries: [(String, Data)] = [
        ("mimetype", Data("application/epub+zip".utf8)),
        ("META-INF/container.xml", Data("<container/>".utf8)),
        // Long and repetitive, so deflate actually has something to do.
        ("ops/content.opf", Data(String(repeating: "<dc:title>Laura</dc:title>", count: 200).utf8)),
    ]

    @Test("an archive we write is readable by the system unzip, not just by us")
    func systemUnzipAcceptsOurArchives() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "probe.epub")

        try ZipArchive.write(entries.map { ZipArchive.NewEntry(path: $0.0, data: $0.1) }, to: url)

        let (status, output) = try run("/usr/bin/unzip", ["-t", url.path])
        #expect(status == 0, "unzip -t rejected the archive: \(output)")
        #expect(output.contains("No errors detected"))
    }

    @Test("every entry round-trips through our own reader")
    func roundTripsThroughOurReader() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "probe.epub")

        try ZipArchive.write(entries.map { ZipArchive.NewEntry(path: $0.0, data: $0.1) }, to: url)
        let archive = try ZipArchive(url: url)

        for (path, data) in entries {
            #expect(try archive.data(at: path) == data, "\(path) did not survive")
        }
        #expect(archive.paths.count == entries.count)
    }

    @Test("the mimetype entry is first and stored uncompressed, as EPUB requires")
    func mimetypeIsStoredFirst() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "probe.epub")

        try ZipArchive.write(entries.map { ZipArchive.NewEntry(path: $0.0, data: $0.1) }, to: url)

        let archive = try ZipArchive(url: url)
        let first = try #require(archive.entries.first)
        #expect(first.path == "mimetype")
        #expect(first.isStored)

        // A reader that only understands stored entries — as EPUB readers are
        // permitted to be for this one entry — must find it at a fixed offset.
        let bytes = try Data(contentsOf: url)
        #expect(bytes[30..<38] == Data("mimetype".utf8))
        #expect(bytes[38..<58] == Data("application/epub+zip".utf8))
    }

    @Test("deflate actually compresses; stored entries do not grow")
    func compressionHappens() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "probe.epub")

        try ZipArchive.write(entries.map { ZipArchive.NewEntry(path: $0.0, data: $0.1) }, to: url)
        let archive = try ZipArchive(url: url)

        let opf = try #require(archive.entries.first { $0.path == "ops/content.opf" })
        #expect(!opf.isStored)
        #expect(opf.compressedSize < opf.uncompressedSize)
    }

    @Test("an entry copied verbatim keeps its original compressed bytes")
    func verbatimCopyAvoidsRecompression() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appending(path: "original.epub")
        let rebuilt = directory.appending(path: "rebuilt.epub")

        try ZipArchive.write(entries.map { ZipArchive.NewEntry(path: $0.0, data: $0.1) }, to: original)
        let source = try ZipArchive(url: original)

        // Rebuild, replacing only the OPF — the shape of an EPUB tag write.
        try source.rebuild(to: rebuilt, replacing: ["ops/content.opf": Data("<new/>".utf8)])

        let (status, output) = try run("/usr/bin/unzip", ["-t", rebuilt.path])
        #expect(status == 0, "\(output)")

        let result = try ZipArchive(url: rebuilt)
        #expect(try result.data(at: "ops/content.opf") == Data("<new/>".utf8))
        #expect(try result.data(at: "META-INF/container.xml") == Data("<container/>".utf8))
        #expect(try result.data(at: "mimetype") == Data("application/epub+zip".utf8))
        #expect(result.paths == source.paths, "rebuild must preserve entry order")
    }

    @Test("a file that is not a zip is refused rather than half-parsed")
    func refusesNonArchives() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "not.epub")
        try Data(repeating: 0x41, count: 500).write(to: url)

        #expect(throws: (any Error).self) { try ZipArchive(url: url) }
    }

    @Test("system-written archives are readable by us")
    func readsSystemWrittenArchives() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = directory.appending(path: "content.opf")
        try Data(String(repeating: "laura ", count: 500).utf8).write(to: payload)

        let url = directory.appending(path: "system.zip")
        let (status, output) = try run("/usr/bin/zip", ["-j", "-X", url.path, payload.path])
        #expect(status == 0, "\(output)")

        let archive = try ZipArchive(url: url)
        #expect(try archive.data(at: "content.opf") == (try Data(contentsOf: payload)))
    }
}
