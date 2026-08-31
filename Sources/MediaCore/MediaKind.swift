public enum MediaKind: String, Sendable, CaseIterable, Codable, Hashable {
    case music, audiobook, movie, tvEpisode
}

/// A container we can open. Extension-driven: cheap, and correct for a library
/// the user curated. Content sniffing only matters for files with a lying
/// extension, which is a phase-5 problem.
public enum ContainerFormat: String, Sendable, CaseIterable, Codable, Hashable {
    case mp3, m4a, m4b, flac, wav, aiff, ogg, opus, aac
    case mp4, mkv, mov, m4v, avi

    public init?(pathExtension: String) {
        guard !pathExtension.isEmpty,
              let f = ContainerFormat(rawValue: pathExtension.lowercased())
        else { return nil }
        self = f
    }

    public var defaultKind: MediaKind {
        switch self {
        case .m4b: .audiobook
        case .mp4, .mkv, .mov, .m4v, .avi: .movie
        default: .music
        }
    }

    /// True where the MP4 metadata atom layout applies (AVFoundation can write these).
    public var isMPEG4Family: Bool {
        switch self {
        case .m4a, .m4b, .mp4, .mov, .m4v: true
        default: false
        }
    }
}
