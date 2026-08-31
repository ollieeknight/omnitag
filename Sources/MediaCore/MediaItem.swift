import Foundation

public struct Chapter: Sendable, Hashable, Codable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var start: TimeInterval
    public var duration: TimeInterval?
    public var title: String

    public init(index: Int, start: TimeInterval, duration: TimeInterval? = nil, title: String) {
        self.index = index; self.start = start; self.duration = duration; self.title = title
    }
}

public struct Artwork: Sendable, Hashable, Codable {
    public enum Role: String, Sendable, Codable { case cover, poster, backdrop }
    public var role: Role
    public var data: Data
    public var mimeType: String

    public init(role: Role = .cover, data: Data, mimeType: String) {
        self.role = role; self.data = data; self.mimeType = mimeType
    }
}

public struct MediaItem: Sendable, Hashable, Codable, Identifiable {
    // ponytail: URL is the identity until a rename/move feature needs to track
    // files across paths — then swap in volume UUID + inode.
    public var id: URL { url }
    public var url: URL
    public var kind: MediaKind
    public var container: ContainerFormat
    public var duration: TimeInterval?
    public var tags: TagSet
    public var chapters: [Chapter]
    public var artwork: [Artwork]

    public init(
        url: URL, kind: MediaKind, container: ContainerFormat, duration: TimeInterval? = nil,
        tags: TagSet = TagSet(), chapters: [Chapter] = [], artwork: [Artwork] = []
    ) {
        self.url = url; self.kind = kind; self.container = container
        self.duration = duration; self.tags = tags
        self.chapters = chapters; self.artwork = artwork
    }
}
