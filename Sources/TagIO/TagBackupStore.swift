import Foundation
import MediaCore

/// Archives the tags a file had *before* a write, so an edit is always
/// reversible even after the app quits. Cheap: tags are kilobytes, media is
/// gigabytes — we never copy the media itself.
public struct TagBackupStore: Sendable {
    public struct Entry: Codable, Sendable {
        public var url: URL
        public var date: Date
        public var tags: TagSet
    }

    public let root: URL

    public init(root: URL) { self.root = root }

    public static var `default`: TagBackupStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return TagBackupStore(root: base.appending(path: "OmniTag/backups"))
    }

    public func record(_ tags: TagSet, for url: URL) throws {
        let directory = root.appending(path: Self.slug(for: url))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = Entry(url: url, date: .now, tags: tags)
        let file = directory.appending(path: "\(entry.date.timeIntervalSince1970).json")
        try JSONEncoder().encode(entry).write(to: file, options: .atomic)
    }

    public func history(for url: URL) -> [Entry] {
        let directory = root.appending(path: Self.slug(for: url))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .compactMap { try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date < $1.date }
    }

    public func mostRecent(for url: URL) -> Entry? { history(for: url).last }

    /// Path-derived folder name. Collisions are harmless (entries carry their
    /// own URL), so a hash beats sanitising arbitrary path characters.
    private static func slug(for url: URL) -> String {
        String(format: "%016llx", UInt64(bitPattern: Int64(url.standardizedFileURL.path.hashValue)))
    }
}
