import Foundation
import MediaCore
import TagIO

/// What the engine needs from a writer. Narrow on purpose: the UI can be tested
/// without touching disk, and a per-format writer only has to satisfy this.
public protocol TagPersisting: Sendable {
    func write(_ tags: TagSet, artwork: [Artwork], chapters: [Chapter]?, to url: URL) async throws
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
        var before: [URL: Snapshot]
        var after: [URL: Snapshot]
    }

    /// Everything that can change on a single item in one user action.
    struct Snapshot: Equatable {
        var tags: TagSet
        var artwork: [Artwork]
        var chapters: [Chapter]
    }

    private let writer: any TagPersisting
    private var items: [URL: MediaItem] = [:]
    private var order: [URL] = []
    private var saved: [URL: Snapshot] = [:]
    private var undoStack: [Batch] = []
    private var redoStack: [Batch] = []

    public init(writer: any TagPersisting) {
        self.writer = writer
    }

    public func load(_ loaded: [MediaItem]) {
        items = Dictionary(uniqueKeysWithValues: loaded.map { ($0.url, $0) })
        order = loaded.map(\.url)
        saved = items.mapValues { Snapshot(tags: $0.tags, artwork: $0.artwork, chapters: $0.chapters) }
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Bring more files in without disturbing what is already here. `load`
    /// resets the saved baseline, which would quietly mark every pending edit
    /// as written; importing a second folder must not do that.
    public func add(_ loaded: [MediaItem]) {
        for item in loaded where items[item.url] == nil {
            items[item.url] = item
            order.append(item.url)
            saved[item.url] = Snapshot(tags: item.tags, artwork: item.artwork, chapters: item.chapters)
        }
    }

    /// Replace an item's on-disk state after a re-read, keeping its baseline in
    /// step so a freshly scanned file does not look dirty.
    public func refreshFromDisk(_ item: MediaItem) {
        guard items[item.url] != nil, saved[item.url] == items[item.url].map({
            Snapshot(tags: $0.tags, artwork: $0.artwork, chapters: $0.chapters)
        }) else { return }
        items[item.url] = item
        saved[item.url] = Snapshot(tags: item.tags, artwork: item.artwork, chapters: item.chapters)
    }

    public var allItems: [MediaItem] { order.compactMap { items[$0] } }

    public func item(at url: URL) -> MediaItem? { items[url] }

    /// Items whose tags, artwork, or chapters differ from what is on disk.
    public var dirtyURLs: [URL] {
        order.filter { url in
            guard let item = items[url], let snap = saved[url] else { return false }
            return item.tags != snap.tags || item.artwork != snap.artwork || item.chapters != snap.chapters
        }
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func apply(_ edit: TagEdit, to urls: [URL]) {
        var batch = Batch(before: [:], after: [:])
        for url in urls {
            guard var item = items[url] else { continue }
            let updated = edit.applied(to: item.tags)
            guard updated != item.tags else { continue }
            batch.before[url] = Snapshot(tags: item.tags, artwork: item.artwork, chapters: item.chapters)
            item.tags = updated
            batch.after[url] = Snapshot(tags: item.tags, artwork: item.artwork, chapters: item.chapters)
            items[url] = item
        }
        guard !batch.after.isEmpty else { return }
        undoStack.append(batch)
        redoStack.removeAll()
    }

    /// Apply tags, artwork, and chapters as one undoable batch (the wizard path).
    ///
    /// `tags` is a **delta**, not a replacement: only the keys it carries are
    /// written, so a selection of twenty parts of one book keeps its per-file
    /// titles and track numbers while gaining the author the provider supplied.
    /// Empty `artwork` means "the provider had none", never "delete the cover".
    // ponytail: no way to clear a key through this path, because nothing in the
    // wizard offers it. Add a `clearing: Set<TagKey>` argument when it does.
    public func applySnapshot(tags: TagSet, artwork: [Artwork], chapters: [Chapter]?, to urls: [URL]) {
        var batch = Batch(before: [:], after: [:])
        for url in urls {
            guard var item = items[url] else { continue }
            let beforeSnap = Snapshot(tags: item.tags, artwork: item.artwork, chapters: item.chapters)
            for (key, value) in tags.values { item.tags[key] = value }
            if !artwork.isEmpty { item.artwork = artwork }
            if let chapters { item.chapters = chapters }
            let afterSnap = Snapshot(tags: item.tags, artwork: item.artwork, chapters: item.chapters)
            guard beforeSnap != afterSnap else { continue }
            batch.before[url] = beforeSnap
            batch.after[url] = afterSnap
            items[url] = item
        }
        guard !batch.after.isEmpty else { return }
        undoStack.append(batch)
        redoStack.removeAll()
    }

    /// Replace the artwork across a selection as one undoable batch. An empty
    /// array here *is* a deletion — unlike `applySnapshot`, where empty means
    /// the provider had nothing to offer.
    public func setArtwork(_ artwork: [Artwork], to urls: [URL]) {
        var batch = Batch(before: [:], after: [:])
        for url in urls {
            guard var item = items[url], item.artwork != artwork else { continue }
            batch.before[url] = Snapshot(tags: item.tags, artwork: item.artwork, chapters: item.chapters)
            item.artwork = artwork
            batch.after[url] = Snapshot(tags: item.tags, artwork: item.artwork, chapters: item.chapters)
            items[url] = item
        }
        guard !batch.after.isEmpty else { return }
        undoStack.append(batch)
        redoStack.removeAll()
    }

    /// How many of these files carry edits that are not on disk. The caller
    /// warns with this before removing them, because removal is not undoable.
    public func unsavedCount(among urls: [URL]) -> Int {
        Set(dirtyURLs).intersection(urls).count
    }

    /// Drop files from the working set — the files themselves are untouched.
    /// The undo history is pruned *per file* rather than per batch: a batch that
    /// also touched files still here has to keep working for them.
    public func remove(_ urls: [URL]) {
        let dropped = Set(urls)
        guard dropped.contains(where: { items[$0] != nil }) else { return }
        for url in dropped {
            items[url] = nil
            saved[url] = nil
        }
        order.removeAll { dropped.contains($0) }
        undoStack = prune(undoStack, dropping: dropped)
        redoStack = prune(redoStack, dropping: dropped)
    }

    private func prune(_ stack: [Batch], dropping urls: Set<URL>) -> [Batch] {
        stack.compactMap { batch in
            var kept = batch
            kept.before = batch.before.filter { !urls.contains($0.key) }
            kept.after = batch.after.filter { !urls.contains($0.key) }
            return kept.after.isEmpty ? nil : kept
        }
    }

    /// Apply only chapter changes as one undoable batch.
    public func applyChapters(_ chapters: [Chapter], to urls: [URL]) {
        var batch = Batch(before: [:], after: [:])
        for url in urls {
            guard var item = items[url] else { continue }
            guard item.chapters != chapters else { continue }
            batch.before[url] = Snapshot(tags: item.tags, artwork: item.artwork, chapters: item.chapters)
            item.chapters = chapters
            batch.after[url] = Snapshot(tags: item.tags, artwork: item.artwork, chapters: item.chapters)
            items[url] = item
        }
        guard !batch.after.isEmpty else { return }
        undoStack.append(batch)
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

    private func restore(_ snapshots: [URL: Snapshot]) {
        for (url, snap) in snapshots {
            items[url]?.tags = snap.tags
            items[url]?.artwork = snap.artwork
            items[url]?.chapters = snap.chapters
        }
    }

    /// Writes every dirty item. A failure never stops the rest: the caller gets
    /// the failures back and those items stay dirty so a retry is one click.
    /// `progress` is called after each file with the URL just attempted, how
    /// many are done, and how many there are: writing chapters remuxes the whole
    /// file, so a book-length m4b is a visible wait, not an instant.
    @discardableResult
    public func save(
        progress: (@Sendable (URL, Int, Int) -> Void)? = nil
    ) async throws -> [SaveFailure] {
        var failures: [SaveFailure] = []
        let pending = dirtyURLs
        var done = 0
        for url in pending {
            guard let item = items[url] else { continue }
            let snap = Snapshot(tags: item.tags, artwork: item.artwork, chapters: item.chapters)
            let savedSnap = saved[url]
            // Only pass chapters to the writer when they actually changed.
            let chaptersChanged = savedSnap.map { $0.chapters != item.chapters } ?? !item.chapters.isEmpty
            do {
                try await writer.write(
                    item.tags, artwork: item.artwork,
                    chapters: chaptersChanged ? item.chapters : nil,
                    to: url)
                saved[url] = snap
            } catch {
                failures.append(SaveFailure(url: url, error: error))
            }
            done += 1
            progress?(url, done, pending.count)
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

    public func write(_ tags: TagSet, artwork: [Artwork], chapters: [Chapter]?, to url: URL) async throws {
        try await MediaTagWriter(backups: backups).write(tags, artwork: artwork, chapters: chapters, to: url)
    }
}
