import Foundation
import MediaCore

/// What the user is looking for. Either a structured search (the fields Audible
/// indexes separately) or free-text keywords — never both, because Audible
/// ignores the structured fields when `keywords` is present.
public struct MetadataQuery: Sendable, Equatable {
    public var keywords: String?
    public var title: String?
    public var author: String?
    public var narrator: String?
    public var asin: String?

    public init(
        keywords: String? = nil, title: String? = nil, author: String? = nil,
        narrator: String? = nil, asin: String? = nil
    ) {
        self.keywords = keywords
        self.title = title
        self.author = author
        self.narrator = narrator
        self.asin = asin
    }

    public var isEmpty: Bool {
        [keywords, title, author, narrator, asin].allSatisfy { $0?.isEmpty ?? true }
    }

    /// Audible's catalogue only honours `keywords`, and it honours them badly:
    /// `title=` returns nothing, `author=` matches unrelated books, and adding an
    /// author to the keywords drops the result count to zero. All verified live
    /// against the UK and US storefronts.
    ///
    /// So the search is run on the title alone and the author is used to *rank*
    /// what comes back — searching for less and sorting better beats searching
    /// for more and getting nothing. `searchLadder` is tried in order until one
    /// rung returns results.
    public var searchLadder: [String] {
        var rungs: [String] = []
        if let keywords, !keywords.isEmpty { rungs.append(keywords) }
        if let title, !title.isEmpty {
            rungs.append(title)
            if let author, !author.isEmpty { rungs.append("\(title) \(author)") }
        } else if let author, !author.isEmpty {
            rungs.append(author)
        }
        if let narrator, !narrator.isEmpty, rungs.isEmpty { rungs.append(narrator) }
        return rungs
    }

    public var searchTerms: String { searchLadder.first ?? "" }

    /// What the wizard's one search field reads and writes. An ASIN or an
    /// Audible link is routed to `asin` rather than to `keywords`, because the
    /// catalogue has books the keyword index cannot reach — pasting the link is
    /// the documented way to get at them, and searching for the URL as text
    /// finds nothing.
    public var searchText: String {
        get { asin ?? searchTerms }
        set {
            if let found = Self.asin(fromPastedText: newValue) {
                asin = found
                keywords = nil
            } else {
                asin = nil
                keywords = newValue
            }
            title = nil
            author = nil
        }
    }

    /// How well a result matches what the user actually asked for. Audible's
    /// relevance ordering ignores the author entirely, so this does not.
    public func score(_ candidate: MetadataCandidate) -> Int {
        var score = 0
        let wanted = (title ?? keywords ?? "").lowercased()
        let found = candidate.title.lowercased()
        if !wanted.isEmpty {
            if found == wanted { score += 100 }
            else if found.hasPrefix(wanted) || found.contains(wanted) { score += 60 }
            else {
                let words = Set(wanted.split(separator: " "))
                let matched = words.filter { found.contains($0) }.count
                score += words.isEmpty ? 0 : (40 * matched) / words.count
            }
        }
        if let author, !author.isEmpty {
            let names = candidate.authors.map { $0.lowercased() }
            if names.contains(author.lowercased()) { score += 80 }
            else if names.contains(where: { $0.contains(author.lowercased()) }) { score += 50 }
        }
        if let narrator, !narrator.isEmpty,
           candidate.narrators.contains(where: { $0.lowercased().contains(narrator.lowercased()) }) {
            score += 30
        }
        return score
    }

    /// Audible's search index has holes — some books it sells are reachable only
    /// by ASIN — so a pasted product URL or a bare ASIN is a first-class query.
    /// `B0…`/`B1…` ten-character identifiers, or any audible.* URL containing one.
    public static func asin(fromPastedText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"\b(B[0-9A-Z]{9})\b"#
        guard let match = trimmed.range(of: pattern, options: [.regularExpression]) else { return nil }
        return String(trimmed[match])
    }

    /// The best opening guess for a file: its ASIN if it has one (an exact hit),
    /// otherwise its tags, otherwise its filename with the noise stripped.
    public init(from tags: TagSet, filename: String) {
        if let asin = tags[.asin]?.stringValue, !asin.isEmpty {
            self.init(asin: asin)
            return
        }
        let title = tags.title ?? tags.album
        let author = tags[.author]?.stringValue ?? tags.artist
        if title?.isEmpty == false || author?.isEmpty == false {
            self.init(title: title, author: author)
            return
        }
        self.init(keywords: Self.cleanedFilename(filename))
    }

    /// Filenames carry rubbish that ruins a search: extensions, bitrates,
    /// bracketed release tags, underscores standing in for spaces.
    static func cleanedFilename(_ filename: String) -> String {
        var name = (filename as NSString).deletingPathExtension
        name = name.replacingOccurrences(
            of: #"[\[\(][^\]\)]*[\]\)]"#, with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: #"[_\.]+"#, with: " ", options: .regularExpression)
        name = name.replacingOccurrences(
            of: #"\b(unabridged|abridged|audiobook|m4b|mp3|\d{2,3}kbps)\b"#,
            with: " ", options: [.regularExpression, .caseInsensitive])
        return name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// One search hit, enough to show a row and fetch the rest.
public struct MetadataCandidate: Sendable, Identifiable, Equatable {
    /// Provider-scoped: an Audible ASIN, an OpenLibrary `/works/` key. Only the
    /// provider that issued it can look it up again.
    public var id: String
    public var title: String
    public var subtitle: String?
    public var authors: [String]
    public var narrators: [String]
    public var publisher: String?
    public var year: Int?
    public var runtimeMinutes: Int?
    public var series: String?
    public var seriesIndex: Int?
    public var summary: String?
    public var artworkURL: URL?

    /// Shown beside the year in a result row. OpenLibrary's `/works/OL123W`
    /// keys mean nothing to a reader, so they are not shown; an ASIN is a
    /// thing people paste and recognise.
    public var displayID: String? {
        id.hasPrefix("/") ? nil : id
    }

    public var byline: String {
        let people = authors.isEmpty ? narrators : authors
        return people.joined(separator: ", ")
    }
}

/// A book with everything a tag write needs.
public struct MetadataDetails: Sendable, Equatable {
    public var book: MetadataRecord
    public var chapters: [Chapter]
}

public struct MetadataRecord: Sendable, Equatable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var authors: [String]
    public var narrators: [String]
    public var publisher: String?
    public var year: Int?
    public var language: String?
    public var summary: String?
    public var genres: [String]
    public var series: String?
    public var seriesIndex: Int?
    public var runtimeMinutes: Int?
    public var artworkURL: URL?
    /// Identifiers the provider supplied. Audible answers with an ASIN,
    /// OpenLibrary with an ISBN; neither has the other's.
    public var asin: String?
    public var isbn: String?

    /// The provider's answer expressed in OmniTag's own vocabulary, ready to be
    /// diffed against what the file currently says.
    public var tagSet: TagSet {
        var tags = TagSet()
        tags.title = title
        if let subtitle, !subtitle.isEmpty { tags[.subtitle] = .string(subtitle) }
        if !authors.isEmpty { tags[.author] = .string(authors.joined(separator: ", ")) }
        if !authors.isEmpty { tags[.artist] = .string(authors.joined(separator: ", ")) }
        if !narrators.isEmpty { tags[.narrator] = .string(narrators.joined(separator: ", ")) }
        if let publisher { tags[.publisher] = .string(publisher) }
        if let year { tags[.year] = .number(year) }
        if !genres.isEmpty { tags.genre = genres.joined(separator: "/") }
        if let summary, !summary.isEmpty { tags[.synopsis] = .string(summary) }
        if let series { tags[.series] = .string(series) }
        if let seriesIndex { tags[.seriesIndex] = .number(seriesIndex) }
        if let asin { tags[.asin] = .string(asin) }
        if let isbn { tags[.isbn] = .string(isbn) }
        if let language { tags[.language] = .string(language) }
        tags.album = title  // players group audiobooks by album
        return tags
    }
}
