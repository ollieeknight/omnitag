import Foundation
import MediaCore
import TagIO

/// What the engine needs from a writer. Narrow on purpose: the UI can be tested
/// without touching disk, and a per-format writer only has to satisfy this.
public protocol TagPersisting: Sendable {
    func write(_ tags: TagSet, to url: URL) async throws
}

/// One user-visible change, applied across a selection.
public enum TagEdit: Sendable, Equatable {
    case set(TagKey, TagValue)
    case clear(TagKey)
    case replace(TagKey, find: String, with: String)

    func applied(to tags: TagSet) -> TagSet {
        var result = tags
        switch self {
        case .set(let key, let value):
            result[key] = value
        case .clear(let key):
            result[key] = nil
        case .replace(let key, let find, let replacement):
            guard let current = tags[key]?.stringValue, current.contains(find) else { return tags }
            result[key] = .string(current.replacingOccurrences(of: find, with: replacement))
        }
        return result
    }
}

public struct SaveFailure: Sendable {
    public let url: URL
    public let error: any Error
}

/// Holds the working copy of the library, applies batched edits, and owns
/// undo/redo. Edits stay in memory until `save()`, so undo before a save costs
/// nothing and undo after a save rewrites the file — one mechanism, both cases.
public actor EditEngine {
    /// A batch: every item a single user action touched, with its before/after.
    private struct Batch {
        var before: [URL: TagSet]
        var after: [URL: TagSet]
    }

    private let writer: any TagPersisting
    private var items: [URL: MediaItem] = [:]
    private var order: [URL] = []
    private var saved: [URL: TagSet] = [:]
    private var undoStack: [Batch] = []
    private var redoStack: [Batch] = []

    public init(writer: any TagPersisting) {
        self.writer = writer
    }

    public func load(_ loaded: [MediaItem]) {
        items = Dictionary(uniqueKeysWithValues: loaded.map { ($0.url, $0) })
        order = loaded.map(\.url)
        saved = items.mapValues(\.tags)
        undoStack.removeAll()
        redoStack.removeAll()
    }

    public var allItems: [MediaItem] { order.compactMap { items[$0] } }

    public func item(at url: URL) -> MediaItem? { items[url] }

    /// Items whose tags differ from what is on disk.
    public var dirtyURLs: [URL] { order.filter { items[$0]?.tags != saved[$0] } }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func apply(_ edit: TagEdit, to urls: [URL]) {
        var batch = Batch(before: [:], after: [:])
        for url in urls {
            guard var item = items[url] else { continue }
            let updated = edit.applied(to: item.tags)
            guard updated != item.tags else { continue }
            batch.before[url] = item.tags
            batch.after[url] = updated
            item.tags = updated
            items[url] = item
        }
        guard !batch.after.isEmpty else { return }
        undoStack.append(batch)
        // A fresh edit abandons the redo branch — the standard, least
        // surprising behaviour, and the reason redo is not a second undo stack.
        redoStack.removeAll()
    }

    public func undo() {
        guard let batch = undoStack.popLast() else { return }
        restore(batch.before)
        redoStack.append(batch)
    }

    public func redo() {
        guard let batch = redoStack.popLast() else { return }
        restore(batch.after)
        undoStack.append(batch)
    }

    private func restore(_ tags: [URL: TagSet]) {
        for (url, value) in tags {
            items[url]?.tags = value
        }
    }

    /// Writes every dirty item. A failure never stops the rest: the caller gets
    /// the failures back and those items stay dirty so a retry is one click.
    @discardableResult
    public func save() async throws -> [SaveFailure] {
        var failures: [SaveFailure] = []
        for url in dirtyURLs {
            guard let item = items[url] else { continue }
            do {
                try await writer.write(item.tags, to: url)
                saved[url] = item.tags
            } catch {
                failures.append(SaveFailure(url: url, error: error))
            }
        }
        return failures
    }
}

/// Production writer: real files, staged and verified, with tag backups.
public struct FileTagWriter: TagPersisting {
    private let backups: TagBackupStore

    public init(backups: TagBackupStore = .default) {
        self.backups = backups
    }

    public func write(_ tags: TagSet, to url: URL) async throws {
        try await MediaTagWriter(backups: backups).write(tags, to: url)
    }
}
