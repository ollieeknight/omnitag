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

    /// Scraped out of a video filename, never typed. The episode picker opens
    /// on the season the file already names, and a movie's year disambiguates
    /// remakes in the result list — both are in the filename of essentially
    /// every ripped file, and both were previously thrown away.
    public var season: Int?
    public var episode: Int?
    public var year: Int?

    public init(
        keywords: String? = nil, title: String? = nil, author: String? = nil,
        narrator: String? = nil, asin: String? = nil,
        season: Int? = nil, episode: Int? = nil, year: Int? = nil
    ) {
        self.keywords = keywords
        self.title = title
        self.author = author
        self.narrator = narrator
        self.asin = asin
        self.season = season
        self.episode = episode
        self.year = year
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
        if let keywords, !keywords.isEmpty {
            rungs.append(keywords)
        }
        if let title, !title.isEmpty {
            rungs.append(title)
            if let author, !author.isEmpty {
                rungs.append("\(title) \(author)")
            }
        } else if let author, !author.isEmpty {
            rungs.append(author)
        }
        if let narrator, !narrator.isEmpty, rungs.isEmpty {
            rungs.append(narrator)
        }
        return rungs
    }

    public var searchTerms: String {
        searchLadder.first ?? ""
    }

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
            if found == wanted {
                score += 100
            } else if found.hasPrefix(wanted) || found.contains(wanted) {
                score += 60
            } else {
                let words = Set(wanted.split(separator: " "))
                let matched = words.filter { found.contains($0) }.count
                score += words.isEmpty ? 0 : (40 * matched) / words.count
            }
        }
        if let author, !author.isEmpty {
            let names = candidate.authors.map { $0.lowercased() }
            if names.contains(author.lowercased()) {
                score += 80
            } else if names.contains(where: { $0.contains(author.lowercased()) }) {
                score += 50
            }
        }
        if let narrator, !narrator.isEmpty,
           candidate.narrators.contains(where: { $0.lowercased().contains(narrator.lowercased()) }) {
            score += 30
        }
        return score
    }

    /// The provider's own order, nudged only by what the filename actually
    /// told us. TMDB ranks by popularity, which puts a remake above the
    /// original — a year scraped from the filename is the one signal that
    /// reliably tells them apart. With no year, this is the identity: a
    /// provider that ranks well is not second-guessed.
    public func ranked(_ candidates: [MetadataCandidate]) -> [MetadataCandidate] {
        guard let year else { return candidates }
        return candidates.enumerated().sorted { a, b in
            let scoreA = Self.yearScore(a.element.year, wanted: year)
            let scoreB = Self.yearScore(b.element.year, wanted: year)
            return scoreA == scoreB ? a.offset < b.offset : scoreA > scoreB
        }.map(\.element)
    }

    /// An exact year wins outright; a year one out still beats an unrelated
    /// one, because a release date and a filename's year often straddle a
    /// new year (a December film named for the year it reached cinemas).
    private static func yearScore(_ found: Int?, wanted: Int) -> Int {
        guard let found else { return 0 }
        return switch abs(found - wanted) {
        case 0: 2
        case 1: 1
        default: 0
        }
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
        let scraped = Self.videoParts(filename)
        let title = tags.title ?? tags.album
        let author = tags[.author]?.stringValue ?? tags.artist
        if title?.isEmpty == false || author?.isEmpty == false {
            self.init(
                title: title, author: author,
                season: tags[.seasonNumber]?.intValue ?? scraped.season,
                episode: tags[.episodeNumber]?.intValue ?? scraped.episode,
                year: tags[.year]?.intValue ?? scraped.year
            )
            return
        }
        self.init(
            keywords: Self.cleanedFilename(filename),
            season: scraped.season, episode: scraped.episode, year: scraped.year
        )
    }

    /// Resolution, source, codec, audio format, and the edition words that
    /// follow a title in a scene release name. Everything from the first one
    /// onwards is the encoder's business, not the film's.
    private static let releaseNoise = {
        let terms = [
            #"\d{3,4}[pi]"#, "4k", "uhd", "hdr", "hevc", "bluray", "blu-ray", "brrip",
            "bdrip", "webrip", "web-dl", "webdl", "hdtv", "dvdrip", "remux",
            "x26[45]", #"h\.?26[45]"#, "xvid", "divx", "aac", "ac3", "dts(-hd)?",
            "truehd", "atmos", #"ddp?5\.1"#, "10bit", "proper", "repack",
            "extended", "remastered"
        ]
        return #"\b("# + terms.joined(separator: "|") + #")\b.*$"#
    }()

    /// Season/episode/year read straight out of a filename. A ripped video is
    /// named `Show.S01E01.…` or `Show 1x01 …` almost without exception, and a
    /// film carries its year — throwing that away and making the user retype
    /// it is the friction this removes.
    static func videoParts(_ filename: String) -> (season: Int?, episode: Int?, year: Int?) {
        let name = (filename as NSString).deletingPathExtension
        var season: Int?
        var episode: Int?
        if let match = name.firstMatch(of: #/[Ss](\d{1,2})[Ee](\d{1,3})|\b(\d{1,2})x(\d{1,3})\b/#) {
            season = (match.1 ?? match.3).flatMap { Int($0) }
            episode = (match.2 ?? match.4).flatMap { Int($0) }
        }
        // A four-digit run that reads as a release year, not part of a title
        // ("2001: A Space Odyssey" is a title; ".1968." is a year) — so it has
        // to be delimited and inside the plausible range for a film.
        let year = name.matches(of: #/[\.\s\(\[](19\d{2}|20\d{2})[\.\s\)\]]/#)
            .compactMap { Int($0.1) }.last
        return (season, episode, year)
    }

    /// Filenames carry rubbish that ruins a search: extensions, bitrates,
    /// bracketed release tags, underscores standing in for spaces.
    static func cleanedFilename(_ filename: String) -> String {
        var name = (filename as NSString).deletingPathExtension
        name = name.replacingOccurrences(
            of: #"[\[\(][^\]\)]*[\]\)]"#, with: " ", options: .regularExpression
        )
        name = name.replacingOccurrences(of: #"[_\.]+"#, with: " ", options: .regularExpression)
        name = name.replacingOccurrences(
            of: #"\b(unabridged|abridged|audiobook|m4b|mp3|\d{2,3}kbps)\b"#,
            with: " ", options: [.regularExpression, .caseInsensitive]
        )
        // Everything from the SxxEyy marker onwards is the episode title and
        // the release group's signature; TMDB's TV search wants the show.
        if let marker = name.range(
            of: #"\s[Ss]\d{1,2}[Ee]\d{1,3}\b|\s\d{1,2}x\d{1,3}\b"#, options: .regularExpression
        ) {
            name = String(name[name.startIndex ..< marker.lowerBound])
        }
        // Video release noise: resolution, source, codec, audio, and the
        // trailing `-GROUP`. Anchored to whole words so a title is never eaten.
        name = name.replacingOccurrences(
            of: Self.releaseNoise,
            with: " ", options: [.regularExpression, .caseInsensitive]
        )
        // A delimited release year is metadata, not part of the title.
        name = name.replacingOccurrences(
            of: #"\s(19\d{2}|20\d{2})\s*$"#, with: " ", options: .regularExpression
        )
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
    /// What this record actually is, stated by the provider that built it —
    /// not guessed from which optional fields happen to be set. `tagSet`
    /// used to infer movie/TV-ness from director/studio/etc being non-nil,
    /// which a movie with no credited director or content rating could slip
    /// past; an explicit kind removes that whole class of bug.
    public var kind: MediaKind
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

    // MARK: movie / TV — TMDB

    public var director: String?
    public var studio: String?
    public var contentRating: String?
    public var showName: String?
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var episodeTitle: String?
    public var tmdbID: String?

    // MARK: music — iTunes

    /// An audiobook's `album` is its own title (players group by album), so
    /// these are music's own fields rather than reuses of the book ones.
    public var album: String?
    public var albumArtist: String?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?

    public init(
        id: String, title: String, subtitle: String? = nil, authors: [String] = [],
        narrators: [String] = [], publisher: String? = nil, year: Int? = nil,
        language: String? = nil, summary: String? = nil, genres: [String] = [],
        series: String? = nil, seriesIndex: Int? = nil, runtimeMinutes: Int? = nil,
        artworkURL: URL? = nil, asin: String? = nil, isbn: String? = nil,
        director: String? = nil, studio: String? = nil, contentRating: String? = nil,
        showName: String? = nil, seasonNumber: Int? = nil, episodeNumber: Int? = nil,
        episodeTitle: String? = nil, tmdbID: String? = nil,
        album: String? = nil, albumArtist: String? = nil,
        trackNumber: Int? = nil, trackTotal: Int? = nil,
        discNumber: Int? = nil, discTotal: Int? = nil,
        kind: MediaKind = .audiobook
    ) {
        self.kind = kind
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.authors = authors
        self.narrators = narrators
        self.publisher = publisher
        self.year = year
        self.language = language
        self.summary = summary
        self.genres = genres
        self.series = series
        self.seriesIndex = seriesIndex
        self.runtimeMinutes = runtimeMinutes
        self.artworkURL = artworkURL
        self.asin = asin
        self.isbn = isbn
        self.director = director
        self.studio = studio
        self.contentRating = contentRating
        self.showName = showName
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.episodeTitle = episodeTitle
        self.album = album
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.tmdbID = tmdbID
    }

    /// Shown under the title in the wizard's summary pane. A book has
    /// authors, an audiobook falls back to narrators (see `MetadataCandidate.
    /// byline`); a movie has a director instead, and a TV episode names its
    /// show — neither has an "author" a reader would recognise.
    public var byline: String {
        if !authors.isEmpty {
            return authors.joined(separator: ", ")
        }
        if !narrators.isEmpty {
            return narrators.joined(separator: ", ")
        }
        if let director, !director.isEmpty {
            return director
        }
        if let showName, !showName.isEmpty {
            return showName
        }
        return ""
    }

    /// The provider's answer expressed in OmniTag's own vocabulary, ready to be
    /// diffed against what the file currently says.
    public var tagSet: TagSet {
        var tags = TagSet()
        tags.title = title
        if let subtitle, !subtitle.isEmpty {
            tags[.subtitle] = .string(subtitle)
        }
        if !authors.isEmpty {
            let authorString = authors.joined(separator: ", ")
            // A track's person is its artist, not its author — `.author` is a
            // book field, and writing it on music puts an audiobook tag on
            // every song. Music's album artist is set from the collection
            // below, which is a different person on a compilation.
            if kind != .music {
                tags[.author] = .string(authorString)
                tags[.albumArtist] = .string(authorString)
            }
            tags[.artist] = .string(authorString)
        }
        if !narrators.isEmpty {
            let narratorString = narrators.joined(separator: ", ")
            tags[.narrator] = .string(narratorString)
            tags[.composer] = .string(narratorString)
        }
        if let publisher {
            tags[.publisher] = .string(publisher)
        }
        if let year {
            tags[.year] = .number(year)
        }
        if !genres.isEmpty {
            tags.genre = genres.joined(separator: "/")
        }
        if let summary, !summary.isEmpty {
            tags[.synopsis] = .string(summary)
            tags[.comment] = .string(summary)
        }
        if let series {
            tags[.series] = .string(series)
        }
        if let seriesIndex {
            tags[.seriesIndex] = .number(seriesIndex)
        }
        if let asin {
            tags[.asin] = .string(asin)
        }
        if let isbn {
            tags[.isbn] = .string(isbn)
        }
        if let language {
            tags[.language] = .string(language)
        }
        if let director {
            tags[.director] = .string(director)
        }
        if let studio {
            tags[.studio] = .string(studio)
        }
        if let contentRating {
            tags[.contentRating] = .string(contentRating)
        }
        if let showName {
            tags[.showName] = .string(showName)
        }
        if let seasonNumber {
            tags[.seasonNumber] = .number(seasonNumber)
        }
        if let episodeNumber {
            tags[.episodeNumber] = .number(episodeNumber)
        }
        if let episodeTitle {
            tags[.episodeTitle] = .string(episodeTitle)
        }
        if let tmdbID {
            tags[.tmdbID] = .string(tmdbID)
        }
        // Music carries a real album, and its own artist/track fields. An
        // audiobook has no album of its own, so players group it by title.
        // Movies and TV have no album concept at all.
        switch kind {
        case .music:
            if let album {
                tags.album = album
            }
            if let albumArtist {
                tags[.albumArtist] = .string(albumArtist)
            }
            if let trackNumber {
                tags[.trackNumber] = .number(trackNumber)
            }
            if let trackTotal {
                tags[.trackTotal] = .number(trackTotal)
            }
            if let discNumber {
                tags[.discNumber] = .number(discNumber)
            }
            if let discTotal {
                tags[.discTotal] = .number(discTotal)
            }
        case .audiobook, .book:
            tags.album = title
        case .movie, .tvEpisode:
            break
        }
        return tags
    }
}
