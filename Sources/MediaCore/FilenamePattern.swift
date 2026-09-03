import Foundation

/// A Mp3tag-style filename pattern: literal text with `%field%` placeholders.
///
/// One type serves both directions. `render` turns a `TagSet` into a filename;
/// `parse` reads a filename back into a `TagSet`. Keeping them together is what
/// stops the two halves drifting — the field vocabulary is declared once, and
/// a pattern that renders is a pattern that parses.
public struct FilenamePattern: Sendable, Equatable {
    public enum Token: Sendable, Equatable {
        case literal(String)
        case field(TagKey)
    }

    public let tokens: [Token]
    public let source: String

    public init(_ source: String) {
        self.source = source
        tokens = Self.tokenise(source)
    }

    public var fields: [TagKey] {
        tokens.compactMap {
            if case let .field(key) = $0 {
                key
            } else {
                nil
            }
        }
    }

    // MARK: - Field vocabulary

    /// The placeholder names, in the order the pattern editor lists them.
    /// A name missing here is not an error: `%mood%` becomes `TagKey.custom`,
    /// which is the same key an unmodelled frame round-trips through.
    public static let vocabulary: [(name: String, key: TagKey)] = [
        ("title", .title), ("artist", .artist), ("albumartist", .albumArtist),
        ("album", .album), ("genre", .genre), ("year", .year),
        ("track", .trackNumber), ("tracktotal", .trackTotal),
        ("disc", .discNumber), ("disctotal", .discTotal),
        ("comment", .comment), ("composer", .composer), ("grouping", .grouping),
        ("author", .author), ("narrator", .narrator), ("series", .series),
        ("seriesindex", .seriesIndex), ("publisher", .publisher),
        ("isbn", .isbn), ("asin", .asin), ("language", .language),
        ("subtitle", .subtitle),
        ("show", .showName), ("season", .seasonNumber), ("episode", .episodeNumber),
        ("episodetitle", .episodeTitle), ("director", .director),
        ("studio", .studio), ("rating", .contentRating)
    ]

    /// Keys written as counting numbers: padded on the way out, parsed as
    /// digits on the way back in. `%year%` is deliberately not one of these —
    /// a year is never zero-padded and never two digits.
    static let counting: Set<TagKey> = [
        .trackNumber, .trackTotal, .discNumber, .discTotal,
        .seasonNumber, .episodeNumber, .seriesIndex
    ]

    static func key(named name: String) -> TagKey {
        let lower = name.lowercased()
        if let match = vocabulary.first(where: { $0.name == lower }) {
            return match.key
        }
        return .custom(name.uppercased())
    }

    public static func label(for key: TagKey) -> String {
        if let match = vocabulary.first(where: { $0.key == key }) {
            return match.name
        }
        if case let .custom(name) = key {
            return name.lowercased()
        }
        return "field"
    }

    // MARK: - Tokenising

    private static func tokenise(_ source: String) -> [Token] {
        var tokens: [Token] = []
        var literal = ""
        var rest = Substring(source)

        func flush() {
            if !literal.isEmpty {
                tokens.append(.literal(literal))
                literal = ""
            }
        }

        while let start = rest.firstIndex(of: "%") {
            literal += rest[rest.startIndex ..< start]
            let afterPercent = rest.index(after: start)
            // "%%" is a literal percent sign.
            if afterPercent < rest.endIndex, rest[afterPercent] == "%" {
                literal += "%"
                rest = rest[rest.index(after: afterPercent)...]
                continue
            }
            guard let close = rest[afterPercent...].firstIndex(of: "%"),
                  close > afterPercent
            else {
                // No closing delimiter: the rest is text the user typed, not a field.
                literal += rest[start...]
                rest = rest[rest.endIndex...]
                break
            }
            flush()
            tokens.append(.field(key(named: String(rest[afterPercent ..< close]))))
            rest = rest[rest.index(after: close)...]
        }
        literal += rest
        flush()
        return tokens
    }

    // MARK: - Tag → filename

    public struct Rendered: Sendable, Equatable {
        /// The filename stem, sanitised. Never contains a path separator.
        public let name: String
        /// Fields the pattern asked for that the file does not carry.
        public let missing: [TagKey]
    }

    public func render(_ tags: TagSet) -> Rendered {
        var name = ""
        var missing: [TagKey] = []
        for token in tokens {
            switch token {
            case let .literal(text):
                name += text
            case let .field(key):
                guard let value = Self.text(for: key, in: tags) else {
                    if !missing.contains(key) {
                        missing.append(key)
                    }
                    continue
                }
                name += value
            }
        }
        return Rendered(name: Self.sanitise(name), missing: missing)
    }

    private static func text(for key: TagKey, in tags: TagSet) -> String? {
        guard let value = tags[key] else { return nil }
        if counting.contains(key), let number = value.intValue {
            return String(format: "%02d", number)
        }
        guard let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty
        else { return nil }
        return string
    }

    /// Makes a rendered name safe to hand to the filesystem. `/` is the path
    /// separator and `:` is what Finder shows as one, so both have to go — a
    /// tag containing either would otherwise write outside the folder.
    static func sanitise(_ name: String) -> String {
        var cleaned = name.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" {
                return "-"
            }
            if CharacterSet.controlCharacters.contains(scalar) {
                return " "
            }
            return Character(scalar)
        }.reduce(into: "") { $0.append($1) }

        cleaned = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        // A leading dot hides the file; a trailing dot or space is silently
        // dropped by some filesystems, which turns two names into one.
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " ."))

        // 255 bytes is the filesystem limit; 200 leaves room for an extension
        // and for the " 2" a collision would add.
        while cleaned.utf8.count > 200 {
            cleaned.removeLast()
        }
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    // MARK: - Filename → tags

    /// Reads `filename` back through this pattern. Returns `nil` when the name
    /// does not match — never a half-filled `TagSet`, because a guess written
    /// across a selection is exactly the silent damage this app refuses.
    public func parse(_ filename: String) -> TagSet? {
        let fields = fields
        guard !fields.isEmpty else { return nil }
        let stem = (filename as NSString).deletingPathExtension

        var expression = "^"
        var captured: [TagKey] = []
        for token in tokens {
            switch token {
            case let .literal(text):
                expression += NSRegularExpression.escapedPattern(for: text)
            case let .field(key):
                // The same field twice has to agree: a back-reference says so
                // in the regex rather than by comparing captures afterwards.
                if let earlier = captured.firstIndex(of: key) {
                    expression += "\\\(earlier + 1)"
                    captured.append(key)
                } else {
                    captured.append(key)
                    expression += Self.counting.contains(key) ? "(\\d+)" : "(.*?)"
                }
            }
        }
        expression += "$"

        guard let regex = try? NSRegularExpression(pattern: expression, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(
                  in: stem, options: [.anchored],
                  range: NSRange(stem.startIndex..., in: stem)
              )
        else { return nil }

        var tags = TagSet()
        for (offset, key) in captured.enumerated() {
            guard offset + 1 < match.numberOfRanges,
                  let range = Range(match.range(at: offset + 1), in: stem)
            else { continue }
            let text = stem[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if Self.counting.contains(key), let number = Int(text) {
                tags[key] = .number(number)
            } else if key == .year, let number = Int(text) {
                tags[key] = .number(number)
            } else {
                tags[key] = .string(text)
            }
        }
        return tags
    }
}
