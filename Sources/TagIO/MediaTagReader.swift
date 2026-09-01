import Foundation
import MediaCore

/// The only reader the rest of the app talks to. Picks a backend per container
/// so callers never have to know that Matroska is the odd one out.
///
/// Adding a format means adding a case here and a reader beside it — nothing
/// upstream changes.
public struct MediaTagReader: Sendable {
    public init() {}

    public func read(_ url: URL) async throws -> MediaItem {
        guard let container = ContainerFormat(pathExtension: url.pathExtension) else {
            throw TagIOError.unsupportedContainer(url.pathExtension)
        }
        return switch container {
        case .mkv: try MatroskaReader().read(url)
        case .epub: try EPUBReader().read(url)
        case .pdf: try PDFReader().read(url)
        default: try await AVTagReader().read(url)
        }
    }

    /// Containers with a reader today. The UI uses this to explain itself
    /// rather than showing a file it will silently fail to open.
    public static func canRead(_ container: ContainerFormat) -> Bool {
        switch container {
        case .mkv, .mp3, .m4a, .m4b, .mp4, .mov, .m4v, .wav, .aiff, .aac: true
        case .epub, .pdf: true
        case .flac, .ogg, .opus, .avi: false
        }
    }

    /// Narrower still: a PDF's "cover" is a rendering of page one, not stored
    /// art, and an EPUB can only replace a cover it already has. mkv artwork
    /// lives in an AttachedFile we do not write yet.
    public static func canWriteArtwork(_ container: ContainerFormat) -> Bool {
        container.isMPEG4Family || container == .mp3 || container == .epub
    }

    /// Writing is narrower than reading, and saying so is the honest UI.
    public static func canWrite(_ container: ContainerFormat) -> Bool {
        container.isMPEG4Family || container == .mp3 || container == .mkv
            || container == .epub || container == .pdf
    }
}

/// The write-side twin of `MediaTagReader`: one entry point, one place that
/// knows which backend owns which container.
public struct MediaTagWriter: Sendable {
    private let backups: TagBackupStore?

    public init(backups: TagBackupStore? = nil) {
        self.backups = backups
    }

    public func write(_ tags: TagSet, artwork: [Artwork] = [], chapters: [Chapter]? = nil, to url: URL) async throws {
        guard let container = ContainerFormat(pathExtension: url.pathExtension) else {
            throw TagIOError.unsupportedContainer(url.pathExtension)
        }
        switch container {
        case .mp3:
            try await ID3TagWriter(backups: backups).write(tags, artwork: artwork, to: url)
        case .mkv:
            try await MatroskaTagWriter(backups: backups).write(tags, to: url)
        case .epub:
            try EPUBTagWriter(backups: backups).write(tags, artwork: artwork, to: url)
        case .pdf:
            try PDFTagWriter(backups: backups).write(tags, to: url)
        case _ where container.isMPEG4Family:
            if let chapters, !chapters.isEmpty {
                try await MPEG4ChapterWriter(backups: backups).write(tags, artwork: artwork, chapters: chapters, to: url)
            } else {
                try await MPEG4TagWriter(backups: backups).write(tags, artwork: artwork, chapters: chapters, to: url)
            }
        default:
            throw TagIOError.unsupportedContainer(container.rawValue)
        }
    }
}
