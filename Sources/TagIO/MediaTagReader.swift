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
        default: try await AVTagReader().read(url)
        }
    }

    /// Containers with a reader today. The UI uses this to explain itself
    /// rather than showing a file it will silently fail to open.
    public static func canRead(_ container: ContainerFormat) -> Bool {
        switch container {
        case .mkv, .mp3, .m4a, .m4b, .mp4, .mov, .m4v, .wav, .aiff, .aac: true
        case .flac, .ogg, .opus, .avi: false
        }
    }

    /// Writing is narrower than reading, and saying so is the honest UI.
    public static func canWrite(_ container: ContainerFormat) -> Bool {
        container.isMPEG4Family
    }
}
