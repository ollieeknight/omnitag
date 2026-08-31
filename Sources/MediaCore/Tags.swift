public enum TagKey: Sendable, Hashable, Codable {
    case title, artist, albumArtist, album, genre, year, trackNumber, trackTotal
    case discNumber, discTotal, comment, composer, grouping, compilation
    case author, narrator, series, seriesIndex, publisher, isbn, asin      // audiobook
    case showName, seasonNumber, episodeNumber, episodeTitle, director,
         studio, contentRating, synopsis                                    // video
    /// Anything a format carries that we do not model. Kept so a round-trip
    /// never silently destroys a frame the user cared about.
    case custom(String)
}

public enum TagValue: Sendable, Hashable, Codable {
    case string(String)
    case number(Int)

    public var stringValue: String? {
        switch self {
        case .string(let s): s
        case .number(let n): String(n)
        }
    }

    public var intValue: Int? {
        switch self {
        case .string(let s): Int(s)
        case .number(let n): n
        }
    }
}

public struct TagSet: Sendable, Hashable, Codable {
    public private(set) var values: [TagKey: TagValue]

    public init(_ values: [TagKey: TagValue] = [:]) { self.values = values }

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

extension TagSet {
    private func string(_ key: TagKey) -> String? { values[key]?.stringValue }
    private mutating func set(_ key: TagKey, _ value: String?) {
        values[key] = value.map { .string($0) }
    }

    public var title: String? { get { string(.title) } set { set(.title, newValue) } }
    public var artist: String? { get { string(.artist) } set { set(.artist, newValue) } }
    public var album: String? { get { string(.album) } set { set(.album, newValue) } }
    public var genre: String? { get { string(.genre) } set { set(.genre, newValue) } }
    public var author: String? { get { string(.author) } set { set(.author, newValue) } }
    public var showName: String? { get { string(.showName) } set { set(.showName, newValue) } }
    public var year: Int? {
        get { values[.year]?.intValue }
        set { values[.year] = newValue.map { .number($0) } }
    }
}
