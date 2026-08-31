import Foundation
import MediaCore
import TagIO

/// The house test library. Real media cannot ship in a repo, so every fixture
/// is silence or black frames carrying real-shaped Twin Peaks metadata: the
/// tag soup is what we are testing, not the audio.
///
/// Point `OMNITAG_REAL_MEDIA` at a folder holding your own copies to run the
/// same assertions against genuine files (see `RealMediaTests`).
enum TwinPeaks {
    struct Fixture: Sendable {
        var filename: String
        var kind: MediaKind
        var container: ContainerFormat
        var tags: TagSet
        var chapters: [Chapter] = []
    }

    static let theme = Fixture(
        filename: "Angelo Badalamenti - Twin Peaks Theme.m4a",
        kind: .music, container: .m4a,
        tags: TagSet([
            .title: .string("Twin Peaks Theme"),
            .artist: .string("Angelo Badalamenti"),
            .albumArtist: .string("Angelo Badalamenti"),
            .album: .string("Twin Peaks (Original Television Soundtrack)"),
            .genre: .string("Soundtrack"),
            .year: .number(1990),
            .trackNumber: .number(1),
            .trackTotal: .number(11),
            .composer: .string("Angelo Badalamenti"),
        ]))

    static let diary = Fixture(
        filename: "The Secret Diary of Laura Palmer.m4b",
        kind: .audiobook, container: .m4b,
        tags: TagSet([
            .title: .string("The Secret Diary of Laura Palmer"),
            .author: .string("Jennifer Lynch"),
            .narrator: .string("Eliza Dushku"),
            .series: .string("Twin Peaks"),
            .seriesIndex: .number(1),
            .publisher: .string("Simon & Schuster Audio"),
            .year: .number(1990),
            .genre: .string("Fiction"),
        ]),
        chapters: [
            Chapter(index: 0, start: 0, title: "July 22, 1984"),
            Chapter(index: 1, start: 0.2, title: "The Man Behind the Mask"),
            Chapter(index: 2, start: 0.4, title: "February 23, 1989"),
        ])

    static let fireWalkWithMe = Fixture(
        filename: "Twin Peaks Fire Walk with Me (1992).mp4",
        kind: .movie, container: .mp4,
        tags: TagSet([
            .title: .string("Twin Peaks: Fire Walk with Me"),
            .year: .number(1992),
            .director: .string("David Lynch"),
            .studio: .string("New Line Cinema"),
            .genre: .string("Mystery"),
            .contentRating: .string("R"),
            .synopsis: .string("The last seven days of Laura Palmer."),
        ]))

    static let northwestPassage = Fixture(
        filename: "Twin Peaks - S01E01 - Northwest Passage.mp4",
        kind: .tvEpisode, container: .mp4,
        tags: TagSet([
            .showName: .string("Twin Peaks"),
            .seasonNumber: .number(1),
            .episodeNumber: .number(1),
            .episodeTitle: .string("Northwest Passage"),
            .title: .string("Northwest Passage"),
            .year: .number(1990),
            .director: .string("David Lynch"),
            .genre: .string("Drama"),
        ]))

    static let all = [theme, diary, fireWalkWithMe, northwestPassage]

    /// Folder of real user-owned media, if the developer supplied one.
    static var realMediaRoot: URL? {
        ProcessInfo.processInfo.environment["OMNITAG_REAL_MEDIA"].map { URL(filePath: $0) }
    }
}

/// A disposable directory containing generated fixtures. Deleted on `deinit`.
final class FixtureLibrary {
    let root: URL

    init() throws {
        root = URL.temporaryDirectory.appending(path: "omnitag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Silent, tagless media of the right container, at `fixture.filename`.
    func makeUntagged(_ fixture: TwinPeaks.Fixture, seconds: Double = 0.6) throws -> URL {
        let destination = root.appending(path: fixture.filename)
        switch fixture.container {
        case .m4a, .m4b:
            try Self.encodeSilence(seconds: seconds, to: destination)
        case .mp4:
            try Self.encodeSilence(seconds: seconds, to: destination)
        default:
            throw TagIOError.unsupportedContainer(fixture.container.rawValue)
        }
        return destination
    }

    /// Fully tagged fixture, written through the production writer — so a
    /// broken writer fails these tests loudly rather than poisoning fixtures.
    func makeTagged(_ fixture: TwinPeaks.Fixture) async throws -> URL {
        let url = try makeUntagged(fixture)
        try await MPEG4TagWriter().write(fixture.tags, to: url)
        return url
    }

    /// 44.1 kHz mono silence encoded to AAC in an MPEG-4 container. `afconvert`
    /// ships with macOS, so no fixture binaries live in the repo.
    private static func encodeSilence(seconds: Double, to destination: URL) throws {
        let frames = Int(44_100 * seconds)
        let wav = destination.deletingPathExtension().appendingPathExtension("wav")
        var data = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + frames * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); le32(16); le16(1); le16(1)
        le32(44_100); le32(88_200); le16(2); le16(16)
        data.append(contentsOf: Array("data".utf8)); le32(UInt32(frames * 2))
        data.append(Data(count: frames * 2))
        try data.write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/afconvert")
        process.arguments = ["-f", "m4af", "-d", "aac", wav.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TagIOError.unreadable(destination, "afconvert exited \(process.terminationStatus)")
        }
    }
}
