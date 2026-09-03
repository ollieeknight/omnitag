import MediaCore

/// Matroska tag names, which are plain strings rather than four-byte atoms, and
/// which mean different things at different *target levels*: a TITLE at level 70
/// names the series, at level 50 it names the episode. Ignoring the level is why
/// so many taggers show every episode as "Twin Peaks".
enum MatroskaKeyMap {
    /// Level 50 = episode/movie, the level a file with no explicit target means.
    static let defaultTargetLevel = 50
    static let collectionLevel = 70
    static let seasonLevel = 60

    /// Names whose meaning does not depend on the level.
    static let names: [String: TagKey] = [
        "ARTIST": .artist,
        "ALBUM": .album,
        "ALBUM_ARTIST": .albumArtist,
        "COMPOSER": .composer,
        "GENRE": .genre,
        "COMMENT": .comment,
        "DESCRIPTION": .synopsis,
        "SUMMARY": .synopsis,
        "SYNOPSIS": .synopsis,
        "DIRECTOR": .director,
        "PRODUCTION_STUDIO": .studio,
        "PUBLISHER": .publisher,
        "LAW_RATING": .contentRating,
        "DATE_RELEASED": .year,
        "DATE_RELEASE": .year,
        "DATE": .year,
        "SUBTITLE": .episodeTitle,
        "ISBN": .isbn,
        "NARRATOR": .narrator,
        "AUTHOR": .author,
        "TOTAL_PARTS": .trackTotal,
        "TMDB": .tmdbID
    ]

    static let numericKeys: Set<TagKey> = [
        .year, .trackNumber, .trackTotal, .seasonNumber, .episodeNumber, .seriesIndex
    ]

    /// The two names that only make sense once you know what they are attached to.
    static func key(for name: String, targetLevel: Int) -> TagKey? {
        let name = name.uppercased()
        switch name {
        case "TITLE":
            return switch targetLevel {
            case collectionLevel...: .showName
            case seasonLevel: .album
            default: .title
            }
        case "PART_NUMBER":
            return switch targetLevel {
            case collectionLevel...: .seriesIndex
            case seasonLevel: .seasonNumber
            default: .episodeNumber
            }
        default:
            return names[name] ?? .custom("mkv/\(name)")
        }
    }

    /// Write direction: the name and target level a key belongs at. Mirrors
    /// `key(for:targetLevel:)` so a written file reads back identically.
    static func writeName(for key: TagKey) -> (name: String, level: Int)? {
        switch key {
        case .showName: ("TITLE", collectionLevel)
        case .seriesIndex: ("PART_NUMBER", collectionLevel)
        case .seasonNumber: ("PART_NUMBER", seasonLevel)
        case .title: ("TITLE", defaultTargetLevel)
        case .episodeNumber: ("PART_NUMBER", defaultTargetLevel)
        case .album: ("ALBUM", seasonLevel)
        case let .custom(name):
            name.hasPrefix("mkv/")
                ? (String(name.dropFirst(4)), defaultTargetLevel)
                : (name.uppercased(), defaultTargetLevel)
        default:
            names.first { $0.value == key }.map { ($0.key, defaultTargetLevel) }
        }
    }

    /// Matroska dates are ISO-ish (`1990-04-08`); keep the year.
    static func value(_ string: String, for key: TagKey) -> TagValue {
        guard numericKeys.contains(key) else { return .string(string) }
        if let number = Int(string) {
            return .number(number)
        }
        if key == .year, let year = Int(string.prefix(4)) {
            return .number(year)
        }
        return .string(string)
    }
}
