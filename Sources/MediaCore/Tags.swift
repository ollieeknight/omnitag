public enum TagKey: Sendable, Hashable, Codable {
    case title, artist, albumArtist, album, genre, year, trackNumber, trackTotal
    case discNumber, discTotal, comment, composer, grouping, compilation
    case author, narrator, series, seriesIndex, publisher, isbn, asin // audiobook
    case language, subtitle // books
    case showName, seasonNumber, episodeNumber, episodeTitle, director,
         studio, contentRating, synopsis, tmdbID // video
    /// Anything a format carries that we do not model. Kept so a round-trip
    /// never silently destroys a frame the user cared about.
    case custom(String)

    public static func standardFields(for kind: MediaKind) -> [(key: TagKey, label: String)] {
        switch kind {
        case .music:
            [(.title, "Title"), (.artist, "Artist"), (.albumArtist, "Album Artist"),
             (.album, "Album"), (.genre, "Genre"), (.year, "Year"),
             (.trackNumber, "Track"), (.trackTotal, "of"), (.composer, "Composer")]
        case .audiobook:
            [(.title, "Title"), (.subtitle, "Subtitle"), (.author, "Author"),
             (.narrator, "Narrator"), (.series, "Series"), (.seriesIndex, "Book #"),
             (.publisher, "Publisher"), (.year, "Year"), (.genre, "Genre"),
             (.isbn, "ISBN"), (.asin, "ASIN"), (.synopsis, "Summary")]
        case .book:
            [(.title, "Title"), (.subtitle, "Subtitle"), (.author, "Author"),
             (.series, "Series"), (.seriesIndex, "Book #"), (.publisher, "Publisher"),
             (.year, "Year"), (.genre, "Subjects"), (.language, "Language"),
             (.isbn, "ISBN"), (.synopsis, "Description")]
        case .movie:
            [(.title, "Title"), (.year, "Year"), (.director, "Director"),
             (.studio, "Studio"), (.genre, "Genre"), (.contentRating, "Rating"),
             (.synopsis, "Synopsis"), (.tmdbID, "TMDB ID")]
        case .tvEpisode:
            [(.title, "Title"), (.showName, "Show"), (.seasonNumber, "Season"),
             (.episodeNumber, "Episode"), (.episodeTitle, "Episode Title"),
             (.year, "Year"), (.director, "Director"), (.genre, "Genre"),
             (.synopsis, "Synopsis"), (.tmdbID, "TMDB ID")]
        }
    }

    /// The display name for a field, wherever one is shown — the wizard's tag
    /// table, the inspector, the rename sheet. `standardFields` is the source:
    /// deriving a label from the enum case name instead gives "Tmdb Id".
    public static func label(for key: TagKey) -> String {
        if case let .custom(name) = key {
            return name.capitalized
        }
        for kind in MediaKind.allCases {
            if let match = standardFields(for: kind).first(where: { $0.key == key }) {
                return match.label
            }
        }
        return String(describing: key)
            .replacing(#/([a-z])([A-Z])/#) { "\($0.output.1) \($0.output.2)" }
            .capitalized
    }
}

public enum TagValue: Sendable, Hashable, Codable {
    case string(String)
    case number(Int)

    public var stringValue: String? {
        switch self {
        case let .string(s): s
        case let .number(n): String(n)
        }
    }

    public var intValue: Int? {
        switch self {
        case let .string(s): Int(s)
        case let .number(n): n
        }
    }
}

public struct TagSet: Sendable, Hashable, Codable {
    public private(set) var values: [TagKey: TagValue]

    public init(_ values: [TagKey: TagValue] = [:]) {
        self.values = values
    }

    public subscript(key: TagKey) -> TagValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    /// Keys whose value differs between the two sets, in either direction.
    public func changedKeys(to other: TagSet) -> Set<TagKey> {
        Set(values.keys).union(other.values.keys).filter { values[$0] != other.values[$0] }
    }

    /// Fields that agree across every item. Used by the inspector to decide
    /// which fields show a value and which show `<multiple values>`.
    public static func common(of sets: [TagSet]) -> TagSet {
        guard let first = sets.first else { return TagSet() }
        return TagSet(first.values.filter { key, value in
            sets.allSatisfy { $0.values[key] == value }
        })
    }
}

public extension TagSet {
    private func string(_ key: TagKey) -> String? {
        values[key]?.stringValue
    }

    private mutating func set(_ key: TagKey, _ value: String?) {
        values[key] = value.map { .string($0) }
    }

    var title: String? {
        get { string(.title) } set { set(.title, newValue) }
    }

    var artist: String? {
        get { string(.artist) } set { set(.artist, newValue) }
    }

    var album: String? {
        get { string(.album) } set { set(.album, newValue) }
    }

    var genre: String? {
        get { string(.genre) } set { set(.genre, newValue) }
    }

    var author: String? {
        get { string(.author) } set { set(.author, newValue) }
    }

    var showName: String? {
        get { string(.showName) } set { set(.showName, newValue) }
    }

    var year: Int? {
        get { values[.year]?.intValue }
        set { values[.year] = newValue.map { .number($0) } }
    }
}
