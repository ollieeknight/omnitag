import Foundation
import MediaCore

/// A field-by-field comparison between what the file currently says and what a
/// provider proposes. The wizard shows this as a two-column table with
/// checkboxes; the three merge strategies correspond to the three buttons.
public struct TagDiff: Sendable {
    public struct Row: Sendable, Identifiable {
        public var id: String { String(describing: key) }
        public let key: TagKey
        public let current: TagValue?
        public var proposed: TagValue?

        public var isChanged: Bool { current != proposed }
    }

    public var rows: [Row]

    public init(current: TagSet, proposed: TagSet) {
        let allKeys = Set(current.values.keys).union(proposed.values.keys)
        rows = allKeys.sorted(by: { "\($0)" < "\($1)" }).map { key in
            Row(key: key, current: current[key], proposed: proposed[key])
        }
    }

    /// Fill only what the file does not already have.
    public func merged(into current: TagSet) -> TagSet {
        var result = current
        for row in rows where row.current == nil {
            guard let proposed = row.proposed else { continue }
            result[row.key] = proposed
        }
        return result
    }

    /// Replace only the ticked keys; leave everything else alone.
    public func overwriting(_ keys: Set<TagKey>, into current: TagSet) -> TagSet {
        var result = current
        for row in rows where keys.contains(row.key) {
            result[row.key] = row.proposed
        }
        return result
    }

    /// The ticked rows, as a delta ready to merge into each selected file.
    /// A row edited down to an empty string is a row the user wants left alone,
    /// not a tag they want written blank — the wizard has no "clear" action.
    public func delta(for keys: Set<TagKey>) -> TagSet {
        var result = TagSet()
        for row in rows where keys.contains(row.key) {
            guard let proposed = row.proposed else { continue }
            if let text = proposed.stringValue, text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            result[row.key] = proposed
        }
        return result
    }

    /// Keys the wizard should tick for each of the three spec'd actions.
    public func keys(for action: MergeAction) -> Set<TagKey> {
        switch action {
        case .merge: Set(rows.filter { $0.current == nil && $0.proposed != nil }.map(\.key))
        case .overwriteAll: Set(rows.filter { $0.proposed != nil }.map(\.key))
        case .none: []
        }
    }

    public enum MergeAction: String, Sendable, CaseIterable, Identifiable {
        /// Fill only what the file does not already have.
        case merge = "Fill empty"
        /// Take every field the provider supplied.
        case overwriteAll = "Take all"
        /// Write nothing; start ticking by hand.
        case none = "None"

        public var id: String { rawValue }
    }

    /// Replace the tag set entirely with the provider's values.
    public func overwriteAll() -> TagSet {
        TagSet(Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            row.proposed.map { (row.key, $0) }
        }))
    }
}

/// Pairs file chapters with provider chapters by index. The wizard shows this
/// side by side; the bulk tools (rename, keep-titles-take-times, shift) operate
/// on the result.
public struct ChapterDiff: Sendable {
    public struct Row: Sendable, Identifiable {
        public var id: Int { index }
        public let index: Int
        public let current: Chapter?
        public var proposed: Chapter?
    }

    public var rows: [Row]

    public init(current: [Chapter], proposed: [Chapter]) {
        let count = max(current.count, proposed.count)
        rows = (0..<count).map { i in
            Row(
                index: i,
                current: i < current.count ? current[i] : nil,
                proposed: i < proposed.count ? proposed[i] : nil)
        }
    }

    /// Keep the file's chapters, appending any extras the provider has.
    public func keepMine() -> [Chapter] {
        rows.enumerated().map { offset, row in
            if let current = row.current {
                return current
            }
            // Beyond the file's range: take the provider's chapter.
            return row.proposed.map { Chapter(index: offset, start: $0.start, duration: $0.duration, title: $0.title) }
                ?? Chapter(index: offset, start: 0, title: "Chapter \(offset + 1)")
        }
    }

    /// Replace everything with the provider's chapters.
    public func takeTheirs() -> [Chapter] {
        rows.compactMap { row in
            row.proposed.map { Chapter(index: row.index, start: $0.start, duration: $0.duration, title: $0.title) }
        }
    }

    /// File's titles, provider's times. Beyond the file's count, take both from
    /// the provider. The "keep my titles, take their times" toggle in the wizard.
    public func keepTitlesTakeTimes() -> [Chapter] {
        rows.enumerated().compactMap { offset, row in
            guard let proposed = row.proposed else {
                // Provider has fewer chapters; keep the file's.
                return row.current
            }
            let title = row.current?.title ?? proposed.title
            return Chapter(index: offset, start: proposed.start, duration: proposed.duration, title: title)
        }
    }

    /// How the chapters step reconciles the file's chapters with the provider's.
    /// Applied to the rows themselves rather than to the result, so the table the
    /// user edits is the table that gets written — picking a strategy after
    /// hand-editing a title used to silently discard the edit.
    public enum MergeStrategy: String, Sendable, CaseIterable, Identifiable {
        case takeTheirs = "Take their chapters"
        case keepMine = "Keep mine, add extras"
        case keepTitlesTakeTimes = "Keep my titles, take their times"

        public var id: String { rawValue }
    }

    /// The rows rewritten so `proposed` is what the strategy would write.
    public func applying(_ strategy: MergeStrategy) -> ChapterDiff {
        var copy = self
        let resolved: [Chapter]
        switch strategy {
        case .takeTheirs: resolved = takeTheirs()
        case .keepMine: resolved = keepMine()
        case .keepTitlesTakeTimes: resolved = keepTitlesTakeTimes()
        }
        copy.rows = copy.rows.enumerated().map { offset, row in
            var updated = row
            updated.proposed = offset < resolved.count ? resolved[offset] : nil
            return updated
        }
        return copy
    }

    /// What the wizard will write: whatever the (possibly hand-edited) rows say.
    public var resolved: [Chapter] {
        rows.compactMap { row in
            row.proposed.map { Chapter(index: row.index, start: $0.start, duration: $0.duration, title: $0.title) }
        }
    }

    /// Retitle every row. `%n%` becomes the 1-based index, `%title%` the title
    /// the row already carries — an 85-chapter book is not renamed by hand.
    public func renamingAll(with pattern: String) -> ChapterDiff {
        var copy = self
        copy.rows = copy.rows.enumerated().map { offset, row in
            guard let proposed = row.proposed else { return row }
            var updated = row
            updated.proposed?.title = pattern
                .replacingOccurrences(of: "%n%", with: String(offset + 1))
                .replacingOccurrences(of: "%title%", with: proposed.title)
            return updated
        }
        return copy
    }

    /// Move every start time, for the intro a provider did not account for.
    public func shiftingAll(by offset: TimeInterval) -> ChapterDiff {
        var copy = self
        copy.rows = copy.rows.map { row in
            var updated = row
            if let start = row.proposed?.start { updated.proposed?.start = max(0, start + offset) }
            return updated
        }
        return copy
    }

    /// Apply a rename pattern to every chapter. `%n%` becomes the 1-based index.
    public static func applyRenamePattern(_ pattern: String, to chapters: [Chapter]) -> [Chapter] {
        chapters.enumerated().map { offset, chapter in
            var renamed = chapter
            renamed.title = pattern.replacingOccurrences(of: "%n%", with: String(offset + 1))
            return renamed
        }
    }

    /// Shift every start time by a fixed offset. Negative shifts clamp to zero.
    public static func shiftAllTimes(_ chapters: [Chapter], by offset: TimeInterval) -> [Chapter] {
        chapters.map { chapter in
            var shifted = chapter
            shifted.start = max(0, chapter.start + offset)
            return shifted
        }
    }
}
