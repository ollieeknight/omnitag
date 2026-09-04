import Foundation
import MediaCore
import TagIO

/// What the engine needs from a writer. Narrow on purpose: the UI can be tested
/// without touching disk, and a per-format writer only has to satisfy this.
public protocol TagPersisting: Sendable {
    func write(
        _ tags: TagSet, artwork: [Artwork], chapters: [Chapter]?,
        subtitleTracks: [SubtitleTrack]?, to url: URL
    ) async throws
}

/// A text transform over one field's existing value. The steps a saved
/// action is built from — see `ROADMAP.md` item 2.
public enum TextTransform: String, Sendable, Equatable, CaseIterable, Identifiable {
    case titleCase = "Title Case"
    case upperCase = "UPPER CASE"
    case lowerCase = "lower case"
    case sentenceCase = "Sentence case"
    case trimWhitespace = "Trim Whitespace"

    public var id: String {
        rawValue
    }

    /// Words a title leaves lowercase unless they start it. Deliberately
    /// short: an aggressive list mangles real titles more often than it helps.
    private static let smallWords: Set = [
        "a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "nor",
        "of", "on", "or", "the", "to", "with"
    ]

    func applied(to text: String) -> String {
        switch self {
        case .upperCase:
            text.uppercased()
        case .lowerCase:
            text.lowercased()
        case .trimWhitespace:
            text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .sentenceCase:
            text.lowercased().prefix(1).uppercased() + text.lowercased().dropFirst()
        case .titleCase:
            Self.titleCased(text)
        }
    }

    private static func titleCased(_ text: String) -> String {
        let words = text.lowercased().split(separator: " ", omittingEmptySubsequences: false)
        return words.enumerated().map { index, word in
            // The first word is always capitalised, however small it is.
            guard index > 0, smallWords.contains(String(word)) else {
                return word.prefix(1).uppercased() + word.dropFirst()
            }
            return String(word)
        }.joined(separator: " ")
    }
}

/// One user-visible change, applied across a selection.
public enum TagEdit: Sendable, Equatable {
    case set(TagKey, TagValue)
    case clear(TagKey)
    case replace(TagKey, find: String, with: String)
    case transform(TagKey, TextTransform)
    case copyField(from: TagKey, to: TagKey)
    case swapFields(TagKey, TagKey)

    /// What this edit would do, without doing it — so a sheet can show a
    /// row-by-row preview built from the same code that performs the write.
    /// A preview computed a second way is a preview that can lie.
    public func previewed(on tags: TagSet) -> TagSet {
        applied(to: tags)
    }

    func applied(to tags: TagSet) -> TagSet {
        var result = tags
        switch self {
        case let .set(key, value):
            result[key] = value
        case let .clear(key):
            result[key] = nil
        case let .replace(key, find, replacement):
            guard let current = tags[key]?.stringValue, current.contains(find) else { return tags }
            result[key] = .string(current.replacingOccurrences(of: find, with: replacement))
        case let .transform(key, transform):
            // Only text transforms, and only on text: upper-casing a
            // `.number` would stringify it and lose the type the writers
            // key on for atoms like `trkn`.
            guard case let .string(current)? = tags[key] else { return tags }
            result[key] = .string(transform.applied(to: current))
        case let .copyField(source, destination):
            // An empty source clears the destination rather than doing
            // nothing: "copy" means the two end up the same either way.
            result[destination] = tags[source]
        case let .swapFields(one, other):
            result[one] = tags[other]
            result[other] = tags[one]
        }
        return result
    }
}

public enum RenameError: LocalizedError {
    case destinationExists(URL)

    public var errorDescription: String? {
        switch self {
        case let .destinationExists(url):
            "A file called \(url.lastPathComponent) is already there."
        }
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

    /// One undoable user action. Tag work is a before/after snapshot held in
    /// memory; a rename already happened on disk, so undoing one means moving
    /// the files back rather than restoring a value.
    private enum Step {
        case edit(Batch)
        case rename([RenameMove])
    }

    /// Everything that can change on a single item in one user action.
    struct Snapshot: Equatable {
        var kind: MediaKind
        var tags: TagSet
        var artwork: [Artwork]
        var chapters: [Chapter]
        var subtitleTracks: [SubtitleTrack]
    }

    private func snapshot(of item: MediaItem) -> Snapshot {
        Snapshot(
            kind: item.kind, tags: item.tags, artwork: item.artwork,
            chapters: item.chapters, subtitleTracks: item.subtitleTracks
        )
    }

    private let writer: any TagPersisting
    private var items: [URL: MediaItem] = [:]
    private var order: [URL] = []
    private var saved: [URL: Snapshot] = [:]
    private var undoStack: [Step] = []
    private var redoStack: [Step] = []

    public init(writer: any TagPersisting) {
        self.writer = writer
    }

    public func load(_ loaded: [MediaItem]) {
        items = Dictionary(uniqueKeysWithValues: loaded.map { ($0.url, $0) })
        order = loaded.map(\.url)
        saved = items.mapValues { snapshot(of: $0) }
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
            saved[item.url] = snapshot(of: item)
        }
    }

    /// Replace an item's on-disk state after a re-read, keeping its baseline in
    /// step so a freshly scanned file does not look dirty.
    public func refreshFromDisk(_ item: MediaItem) {
        guard items[item.url] != nil, saved[item.url] == items[item.url].map(snapshot(of:)) else { return }
        items[item.url] = item
        saved[item.url] = snapshot(of: item)
    }

    public var allItems: [MediaItem] {
        order.compactMap { items[$0] }
    }

    public func item(at url: URL) -> MediaItem? {
        items[url]
    }

    /// Items whose tags, artwork, or chapters differ from what is on disk.
    public var dirtyURLs: [URL] {
        order.filter { url in
            guard let item = items[url], let snap = saved[url] else { return false }
            return item.tags != snap.tags || item.artwork != snap.artwork || item.chapters != snap.chapters
                || item.subtitleTracks != snap.subtitleTracks
        }
    }

    public var canUndo: Bool {
        !undoStack.isEmpty
    }

    public var canRedo: Bool {
        !redoStack.isEmpty
    }

    public func apply(_ edit: TagEdit, to urls: [URL]) {
        var batch = Batch(before: [:], after: [:])
        for url in urls {
            guard var item = items[url] else { continue }
            let updated = edit.applied(to: item.tags)
            guard updated != item.tags else { continue }
            batch.before[url] = snapshot(of: item)
            item.tags = updated
            batch.after[url] = snapshot(of: item)
            items[url] = item
        }
        guard !batch.after.isEmpty else { return }
        undoStack.append(.edit(batch))
        redoStack.removeAll()
    }

    /// Reassign the media kind across a selection as one undoable batch.
    public func setKind(_ kind: MediaKind, to urls: [URL]) {
        var batch = Batch(before: [:], after: [:])
        for url in urls {
            guard var item = items[url], item.kind != kind else { continue }
            batch.before[url] = snapshot(of: item)
            item.kind = kind
            batch.after[url] = snapshot(of: item)
            items[url] = item
        }
        guard !batch.after.isEmpty else { return }
        undoStack.append(.edit(batch))
        redoStack.removeAll()
    }

    /// Apply tags, artwork, and chapters as one undoable batch (the wizard path).
    ///
    /// `tags` is a **delta**, not a replacement: only the keys it carries are
    /// written, so a selection of twenty parts of one book keeps its per-file
    /// titles and track numbers while gaining the author the provider supplied.
    /// Empty `artwork` means "the provider had none", never "delete the cover".
    public func applySnapshot(tags: TagSet, artwork: [Artwork], chapters: [Chapter]?, clearing: Set<TagKey> = [], to urls: [URL]) {
        var batch = Batch(before: [:], after: [:])
        for url in urls {
            guard var item = items[url] else { continue }
            let beforeSnap = snapshot(of: item)
            for key in clearing {
                item.tags[key] = nil
            }
            for (key, value) in tags.values {
                if let string = value.stringValue, string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    item.tags[key] = nil
                } else {
                    item.tags[key] = value
                }
            }
            if !artwork.isEmpty {
                item.artwork = artwork
            }
            if let chapters {
                item.chapters = chapters
            }
            let afterSnap = snapshot(of: item)
            guard beforeSnap != afterSnap else { continue }
            batch.before[url] = beforeSnap
            batch.after[url] = afterSnap
            items[url] = item
        }
        guard !batch.after.isEmpty else { return }
        undoStack.append(.edit(batch))
        redoStack.removeAll()
    }

    /// Replace the artwork across a selection as one undoable batch. An empty
    /// array here *is* a deletion — unlike `applySnapshot`, where empty means
    /// the provider had nothing to offer.
    public func setArtwork(_ artwork: [Artwork], to urls: [URL]) {
        var batch = Batch(before: [:], after: [:])
        for url in urls {
            guard var item = items[url], item.artwork != artwork else { continue }
            batch.before[url] = snapshot(of: item)
            item.artwork = artwork
            batch.after[url] = snapshot(of: item)
            items[url] = item
        }
        guard !batch.after.isEmpty else { return }
        undoStack.append(.edit(batch))
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

    private func prune(_ stack: [Step], dropping urls: Set<URL>) -> [Step] {
        stack.compactMap { step in
            switch step {
            case let .edit(batch):
                var kept = batch
                kept.before = batch.before.filter { !urls.contains($0.key) }
                kept.after = batch.after.filter { !urls.contains($0.key) }
                return kept.after.isEmpty ? nil : .edit(kept)
            case let .rename(moves):
                let kept = moves.filter { !urls.contains($0.to) && !urls.contains($0.from) }
                return kept.isEmpty ? nil : .rename(kept)
            }
        }
    }

    /// Apply only chapter changes as one undoable batch.
    public func applyChapters(_ chapters: [Chapter], to urls: [URL]) {
        var batch = Batch(before: [:], after: [:])
        let sorted = chapters.sorted { $0.start < $1.start }
        for url in urls {
            guard var item = items[url] else { continue }
            guard item.chapters != sorted else { continue }
            batch.before[url] = snapshot(of: item)
            item.chapters = sorted
            batch.after[url] = snapshot(of: item)
            items[url] = item
        }
        guard !batch.after.isEmpty else { return }
        undoStack.append(.edit(batch))
        redoStack.removeAll()
    }

    /// Apply subtitle track edits (language, name, default/forced/enabled) as
    /// one undoable batch — single-file only, same as chapters, since a
    /// track's TrackUID identity belongs to one specific file.
    public func applySubtitleTracks(_ subtitleTracks: [SubtitleTrack], to url: URL) {
        guard var item = items[url], item.subtitleTracks != subtitleTracks else { return }
        var batch = Batch(before: [:], after: [:])
        batch.before[url] = snapshot(of: item)
        item.subtitleTracks = subtitleTracks
        batch.after[url] = snapshot(of: item)
        items[url] = item
        undoStack.append(.edit(batch))
        redoStack.removeAll()
    }

    /// Apply a different tag delta to each file as one undoable batch — what
    /// parsing a selection of filenames produces. `applySnapshot` writes one
    /// set of values across a selection; this writes one per file.
    public func applyTagDeltas(_ deltas: [URL: TagSet]) {
        var batch = Batch(before: [:], after: [:])
        for (url, delta) in deltas {
            guard var item = items[url] else { continue }
            let beforeSnap = snapshot(of: item)
            for (key, value) in delta.values {
                if let string = value.stringValue, string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    item.tags[key] = nil
                } else {
                    item.tags[key] = value
                }
            }
            let afterSnap = snapshot(of: item)
            guard beforeSnap != afterSnap else { continue }
            batch.before[url] = beforeSnap
            batch.after[url] = afterSnap
            items[url] = item
        }
        guard !batch.after.isEmpty else { return }
        undoStack.append(.edit(batch))
        redoStack.removeAll()
    }

    // MARK: - Renaming

    /// Move files to the names a `RenamePlan` worked out.
    ///
    /// Unlike a tag edit, this happens on disk immediately: there is no useful
    /// "unsaved rename" state, and a file half-renamed in memory is a file the
    /// next save writes to the wrong path. Undo moves it back.
    ///
    /// A failure never stops the batch — the rest of the selection is renamed
    /// and the failures come back for the caller to show.
    @discardableResult
    public func rename(_ moves: [RenameMove]) -> RenameOutcome {
        var done: [RenameMove] = []
        var failures: [SaveFailure] = []
        for step in moves where step.from != step.to {
            guard items[step.from] != nil else { continue }
            do {
                // Checked again here, not only in the plan: the preview may have
                // been on screen for a while, and the folder is not ours alone.
                guard !FileManager.default.fileExists(atPath: step.to.path) else {
                    throw RenameError.destinationExists(step.to)
                }
                try FileManager.default.moveItem(at: step.from, to: step.to)
                done.append(step)
            } catch {
                failures.append(SaveFailure(url: step.from, error: error))
            }
        }
        guard !done.isEmpty else { return RenameOutcome(renamed: 0, failures: failures, done: []) }
        remap(done)
        undoStack.append(.rename(done))
        redoStack.removeAll()
        return RenameOutcome(renamed: done.count, failures: failures, done: done)
    }

    /// Replays moves that already succeeded once (undo and redo). A file the
    /// user moved in Finder in the meantime is skipped rather than fought over.
    private func move(_ moves: [RenameMove]) {
        var done: [RenameMove] = []
        for step in moves where step.from != step.to {
            guard FileManager.default.fileExists(atPath: step.from.path),
                  !FileManager.default.fileExists(atPath: step.to.path),
                  (try? FileManager.default.moveItem(at: step.from, to: step.to)) != nil
            else { continue }
            done.append(step)
        }
        remap(done)
    }

    /// Re-keys everything the URL identifies: the item, its saved baseline, the
    /// display order, and every snapshot in both history stacks. Missing one of
    /// these is how a renamed file loses its unsaved edits or its undo.
    private func remap(_ moves: [RenameMove]) {
        guard !moves.isEmpty else { return }
        let table = Dictionary(moves.map { ($0.from, $0.to) }, uniquingKeysWith: { _, last in last })
        func mapped(_ url: URL) -> URL {
            table[url] ?? url
        }

        for (from, to) in table {
            guard var item = items.removeValue(forKey: from) else { continue }
            item.url = to
            items[to] = item
            if let snap = saved.removeValue(forKey: from) {
                saved[to] = snap
            }
        }
        order = order.map(mapped)
        undoStack = rekey(undoStack, with: mapped)
        redoStack = rekey(redoStack, with: mapped)
    }

    private func rekey(_ stack: [Step], with mapped: (URL) -> URL) -> [Step] {
        stack.map { step in
            switch step {
            case var .edit(batch):
                batch.before = Dictionary(batch.before.map { (mapped($0.key), $0.value) },
                                          uniquingKeysWith: { first, _ in first })
                batch.after = Dictionary(batch.after.map { (mapped($0.key), $0.value) },
                                         uniquingKeysWith: { first, _ in first })
                return .edit(batch)
            case let .rename(moves):
                return .rename(moves.map { RenameMove(from: $0.from, to: mapped($0.to)) })
            }
        }
    }

    public func undo() {
        guard let step = undoStack.popLast() else { return }
        switch step {
        case let .edit(batch): restore(batch.before)
        case let .rename(moves): move(moves.map { RenameMove(from: $0.to, to: $0.from) })
        }
        redoStack.append(step)
    }

    public func redo() {
        guard let step = redoStack.popLast() else { return }
        switch step {
        case let .edit(batch): restore(batch.after)
        case let .rename(moves): move(moves)
        }
        undoStack.append(step)
    }

    private func restore(_ snapshots: [URL: Snapshot]) {
        for (url, snap) in snapshots {
            items[url]?.kind = snap.kind
            items[url]?.tags = snap.tags
            items[url]?.artwork = snap.artwork
            items[url]?.chapters = snap.chapters
            items[url]?.subtitleTracks = snap.subtitleTracks
        }
    }

    /// Writes every dirty item. A failure never stops the rest: the caller gets
    /// the failures back and those items stay dirty so a retry is one click.
    /// `progress` is called after each file with the URL just attempted, how
    /// many are done, and how many there are: writing chapters remuxes the whole
    /// file, so a book-length m4b is a visible wait, not an instant.
    @discardableResult
    public func save(
        only selection: Set<URL>? = nil,
        progress: (@Sendable (URL, Int, Int) -> Void)? = nil
    ) async throws -> [SaveFailure] {
        var failures: [SaveFailure] = []
        let pending = selection != nil ? Set(dirtyURLs).intersection(selection!) : Set(dirtyURLs)
        guard !pending.isEmpty else { return [] }
        var done = 0
        for url in pending {
            guard let item = items[url] else { continue }
            let snap = snapshot(of: item)
            do {
                // Always hand over the chapters the item carries: an MPEG-4 tag
                // write that skips them rebuilds the file without its chapter
                // track. `nil` means "we have none", and the writer checks the
                // file itself before believing it.
                try await writer.write(
                    item.tags, artwork: item.artwork,
                    chapters: item.chapters.isEmpty ? nil : item.chapters,
                    subtitleTracks: item.subtitleTracks.isEmpty ? nil : item.subtitleTracks,
                    to: url
                )
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

    public func write(
        _ tags: TagSet, artwork: [Artwork], chapters: [Chapter]?,
        subtitleTracks: [SubtitleTrack]?, to url: URL
    ) async throws {
        try await MediaTagWriter(backups: backups).write(
            tags, artwork: artwork, chapters: chapters, subtitleTracks: subtitleTracks, to: url
        )
    }
}
