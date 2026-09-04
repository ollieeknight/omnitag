import Foundation
import MediaCore

/// A field-by-field comparison between what the file currently says and what a
/// provider proposes. The wizard shows this as a two-column table with
/// checkboxes; the three merge strategies correspond to the three buttons.
public struct TagDiff: Sendable {
    public struct Row: Sendable, Identifiable {
        public var id: String {
            String(describing: key)
        }

        public let key: TagKey
        public let current: TagValue?
        public var proposed: TagValue?

        public var isChanged: Bool {
            current != proposed
        }
    }

    public var rows: [Row]

    public init(current: TagSet, proposed: TagSet, kind: MediaKind) {
        // The curated order first — a TV episode reads Title, Show, Season,
        // Episode, not the alphabet's Director, Episode Number, Genre… —
        // then anything the file or provider carries beyond it.
        let standard = TagKey.standardFields(for: kind).map(\.key)
        let extras = Set(current.values.keys).union(proposed.values.keys)
            .subtracting(standard)
            .sorted(by: { "\($0)" < "\($1)" })
        rows = (standard + extras).map { key in
            Row(key: key, current: current[key], proposed: proposed[key])
        }
    }

    /// The ticked rows, as a delta ready to merge into each selected file.
    /// A row edited down to an empty string is a row the user wants left alone,
    /// not a tag they want written blank — the wizard has no "clear" action.
    public func delta(for keys: Set<TagKey>) -> TagSet {
        var result = TagSet()
        for row in rows where keys.contains(row.key) {
            guard let proposed = row.proposed,
                  !(proposed.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            result[row.key] = proposed
        }
        return result
    }

    /// Keys the wizard should tick for each of the three spec'd actions.
    public func keys(for action: MergeAction) -> Set<TagKey> {
        switch action {
        case .merge: Set(rows.filter { $0.current == nil && !($0.proposed?.stringValue?.isEmpty ?? true) }.map(\.key))
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

        public var id: String {
            rawValue
        }
    }
}

/// Pairs file chapters with provider chapters by index. The wizard shows this
/// side by side and writes whatever the (possibly hand-edited) rows say.
public struct ChapterDiff: Sendable {
    public struct Row: Sendable, Identifiable {
        public var id: Int {
            index
        }

        public let index: Int
        public let current: Chapter?
        public var proposed: Chapter?

        public init(index: Int, current: Chapter?, proposed: Chapter?) {
            self.index = index
            self.current = current
            self.proposed = proposed
        }
    }

    public var rows: [Row]

    public init(current: [Chapter], proposed: [Chapter]) {
        let count = max(current.count, proposed.count)
        rows = (0 ..< count).map { i in
            Row(
                index: i,
                current: i < current.count ? current[i] : nil,
                proposed: i < proposed.count ? proposed[i] : nil
            )
        }
    }

    /// The rows rewritten so `proposed` is what would actually be written.
    ///
    /// A file that already has chapters keeps every one of its own timestamps —
    /// they came from the audio, and a provider's cannot be trusted to the second
    /// — and only gains the provider's titles. A file with no chapters takes the
    /// provider's outright, timings and all.
    public func aligned() -> ChapterDiff {
        let file = rows.compactMap(\.current)
        let provider = rows.compactMap(\.proposed)
        var copy = self

        if file.count >= 2 {
            let titles = Self.matchTitles(fileChapters: file, providerChapters: provider)
            copy.rows = file.enumerated().map { index, chapter in
                Row(
                    index: index, current: chapter,
                    proposed: Chapter(
                        index: index, start: chapter.start,
                        duration: chapter.duration, title: titles[index]
                    )
                )
            }
        } else {
            copy.rows = copy.rows.enumerated().map { index, row in
                Row(index: index, current: row.current, proposed: row.proposed ?? row.current)
            }
        }
        return copy
    }

    /// Aligns provider titles onto the file's chapters by timestamp proximity,
    /// left to right.
    ///
    /// Two things make this harder than zipping the lists. Audible's times drift
    /// from the file's by a minute or more over a long book, so the match has to
    /// be nearest-wins rather than exact. And the provider list carries
    /// seconds-long "Part Two" markers that sit on top of a real chapter — taking
    /// one shifts every later title by one, so a candidate whose length is
    /// nothing like the file chapter's is refused.
    /// How many of the file's chapters found a provider title. What the
    /// mismatch notice reports, so it describes the real outcome rather than
    /// promising a match it may not have made.
    public static func matchedCount(fileChapters: [Chapter], providerChapters: [Chapter]) -> Int {
        let matched = matchTitles(fileChapters: fileChapters, providerChapters: providerChapters)
        return zip(fileChapters, matched).count { $0.title != $1 }
    }

    public static func matchTitles(fileChapters: [Chapter], providerChapters: [Chapter]) -> [String] {
        guard !providerChapters.isEmpty else { return fileChapters.map(\.title) }
        if fileChapters.count == providerChapters.count {
            return providerChapters.map(\.title)
        }

        func plausible(_ file: Chapter, _ candidate: Chapter) -> Bool {
            guard let a = file.duration, let b = candidate.duration, a > 0, b > 0 else { return true }
            return min(a, b) / max(a, b) >= 0.5
        }

        var matched = fileChapters.map(\.title)
        var providerIndex = 0
        for (index, file) in fileChapters.enumerated() {
            var best: Int?
            var bestDistance = Double.infinity

            for candidate in providerIndex ..< providerChapters.count {
                let provider = providerChapters[candidate]
                let distance = abs(file.start - provider.start)
                if distance <= 120, distance < bestDistance, plausible(file, provider) {
                    bestDistance = distance
                    best = candidate
                } else if provider.start > file.start + 180 {
                    break
                }
            }

            if let best {
                matched[index] = providerChapters[best].title
                providerIndex = best + 1
            }
        }
        return matched
    }

    /// A Roman numeral, so `Part I` can be told from `Part 1`. Both are
    /// structural, but only the second is a plain number — and a file whose
    /// only markers are `Part I`…`Part V` (Fulgrim) has real information in
    /// them that a renumbering would destroy.
    private static func isRomanNumeral(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { "ivxlcdm".contains($0) }
    }

    private static let genericWords: Set = [
        "chapter", "part", "track", "disc", "section", "book",
        "intro", "outro", "opening", "credits", "prologue", "epilogue",
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
        "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty",
        "first", "second", "third", "fourth", "fifth"
    ]

    /// "Chapter 12" and "07" say nothing the row number does not. A real title
    /// is worth protecting from a provider that only has numbers.
    public static func isGeneric(title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return true
        }
        if Int(trimmed) != nil {
            return true
        }
        let words = trimmed.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return true }
        // A Roman numeral beside a structural word ("Part I") is real: it is
        // the file's own division, and nothing can reconstruct it once gone.
        if words.count == 2, genericWords.contains(words[0]), isRomanNumeral(words[1]) {
            return false
        }
        return words.allSatisfy { word in
            Int(word) != nil || genericWords.contains(word)
        }
    }

    /// Whether this list holds titles worth protecting from a bulk rename.
    ///
    /// **Any** real title counts. A ratio was tried first and had it exactly
    /// backwards: three real titles among twenty-eight generic ones scored
    /// 11% and were silently overwritten, yet those three are precisely the
    /// ones that cannot be recovered — a book that is *mostly* numbered is
    /// more fragile than one that is fully written out, not less. Measured
    /// against a real 50-book library, the ratio mis-classified nine of them.
    public static func hasRichTitles(_ chapters: [Chapter]) -> Bool {
        guard chapters.count >= 2 else { return false }
        return chapters.contains { !isGeneric(title: $0.title) }
    }

    /// The titles a bulk rename would destroy, in file order.
    public static func realTitles(_ chapters: [Chapter]) -> [String] {
        chapters.map(\.title).filter { !isGeneric(title: $0) }
    }

    /// Whether to start with chapters skipped, and what to tell the user.
    ///
    /// Names the titles at risk rather than only saying that some exist: with
    /// three real titles in a twenty-four-row table, "this file has written-out
    /// titles" does not tell you which three to go and look at.
    public static func protectionNotice(file: [Chapter], provider: [Chapter]) -> (skip: Bool, notice: String?) {
        let atRisk = realTitles(file)
        guard hasRichTitles(file), !hasRichTitles(provider), !atRisk.isEmpty else { return (false, nil) }

        let sample = atRisk.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
        let more = atRisk.count > 3 ? " and \(atRisk.count - 3) more" : ""
        let noun = atRisk.count == 1 ? "title" : "titles"
        return (true, "\(atRisk.count) chapter \(noun) in this file would be lost — \(sample)\(more). "
            + "The provider only has numbered ones, so chapters start skipped.")
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
}
