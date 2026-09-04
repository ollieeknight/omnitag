import Foundation

public struct Chapter: Sendable, Hashable, Codable, Identifiable {
    public var id: Int {
        index
    }

    public var index: Int
    public var start: TimeInterval
    public var duration: TimeInterval?
    public var title: String

    public init(index: Int, start: TimeInterval, duration: TimeInterval? = nil, title: String) {
        self.index = index
        self.start = start
        self.duration = duration
        self.title = title
    }
}

public struct Artwork: Sendable, Hashable, Codable {
    public enum Role: String, Sendable, Codable { case cover, poster, backdrop }
    public var role: Role
    public var data: Data
    public var mimeType: String

    public init(role: Role = .cover, data: Data, mimeType: String) {
        self.role = role
        self.data = data
        self.mimeType = mimeType
    }
}

public struct SubtitleTrack: Sendable, Hashable, Codable, Identifiable {
    public var id: UInt64 {
        trackUID
    }

    public var trackUID: UInt64
    public var codecID: String
    public var language: String?
    public var name: String?
    public var isDefault: Bool
    public var isForced: Bool
    public var isEnabled: Bool

    public init(
        trackUID: UInt64, codecID: String, language: String? = nil, name: String? = nil,
        isDefault: Bool = false, isForced: Bool = false, isEnabled: Bool = true
    ) {
        self.trackUID = trackUID
        self.codecID = codecID
        self.language = language
        self.name = name
        self.isDefault = isDefault
        self.isForced = isForced
        self.isEnabled = isEnabled
    }
}

public struct MediaItem: Sendable, Hashable, Codable, Identifiable {
    // ponytail: URL is the identity until a rename/move feature needs to track
    // files across paths — then swap in volume UUID + inode.
    public var id: URL {
        url
    }

    public var url: URL
    public var kind: MediaKind
    public var container: ContainerFormat
    public var duration: TimeInterval?
    public var tags: TagSet
    public var chapters: [Chapter]
    public var artwork: [Artwork]
    public var subtitleTracks: [SubtitleTrack]

    public init(
        url: URL, kind: MediaKind, container: ContainerFormat, duration: TimeInterval? = nil,
        tags: TagSet = TagSet(), chapters: [Chapter] = [], artwork: [Artwork] = [],
        subtitleTracks: [SubtitleTrack] = []
    ) {
        self.url = url
        self.kind = kind
        self.container = container
        self.duration = duration
        self.tags = tags
        self.chapters = chapters
        self.artwork = artwork
        self.subtitleTracks = subtitleTracks
    }
}

public extension Artwork {
    /// The image type read from the bytes themselves. Containers lie about this
    /// — AVFoundation reports no MIME at all, and a PNG cover written back as
    /// `image/jpeg` is a tag no player can decode.
    static func sniffMimeType(_ data: Data) -> String {
        // Copied to an Array first: `data` is often a slice of a parsed frame,
        // and a slice's indices start where it was cut, not at zero.
        let head = Array(data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "image/png"
        }
        if head.starts(with: [0x47, 0x49, 0x46]) {
            return "image/gif"
        }
        if head.count == 12, head.starts(with: [0x52, 0x49, 0x46, 0x46]),
           head[8 ... 11] == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        return "image/jpeg"
    }
}
