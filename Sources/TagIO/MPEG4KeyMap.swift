import AVFoundation
import MediaCore

/// One bidirectional table shared by the reader and the writer, so a key can
/// never be readable but unwritable (or vice versa) — the classic source of
/// "why did my edit vanish on save".
///
/// Atom choices follow what Music.app, Plex, Infuse and Audiobookshelf already
/// read, so a file tagged here is not tagged *only* for here.
enum MPEG4KeyMap {
    /// `TagKey` → MPEG-4 atom code, written as `itsk/<code>` text atoms.
    static let atoms: [TagKey: String] = [
        .title: "©nam",
        .artist: "©ART",
        .albumArtist: "aART",
        .album: "©alb",
        .genre: "©gen",
        .comment: "©cmt",
        .composer: "©wrt",
        .grouping: "©grp",
        .year: "©day",
        .publisher: "©pub",
        .narrator: "©nrt",
        .author: "©aut",
        .director: "©dir",
        .synopsis: "ldes",
        .compilation: "cpil",
        .showName: "tvsh",
        .seasonNumber: "tvsn",
        .episodeNumber: "tves",
        .episodeTitle: "tven"
    ]

    /// Keys stored in one packed `index/total` atom rather than two text atoms.
    static let pairAtoms: [(atom: String, index: TagKey, total: TagKey)] = [
        ("trkn", .trackNumber, .trackTotal),
        ("disk", .discNumber, .discTotal)
    ]

    /// No standard atom exists, so these go in freeform `----` atoms under the
    /// iTunes mean, using the names Audiobookshelf and Mp3tag already use.
    static let freeformNames: [TagKey: String] = [
        .series: "SERIES",
        .seriesIndex: "SERIES-PART",
        .isbn: "ISBN",
        .asin: "ASIN",
        .subtitle: "SUBTITLE",
        .language: "LANGUAGE",
        .studio: "STUDIO",
        // Real freeform atom name Apple itself uses for the rating string.
        .contentRating: "iTunEXTC",
        // No standard atom for a provider id; Plex/Jellyfin-style tools already
        // look for "tmdb" under com.apple.iTunes in freeform atoms.
        .tmdbID: "tmdb"
    ]

    /// Values that must come back as `.number`, not `.string`, after a
    /// round-trip through a text atom.
    static let numericKeys: Set<TagKey> = [
        .year, .trackNumber, .trackTotal, .discNumber, .discTotal,
        .seriesIndex, .seasonNumber, .episodeNumber
    ]

    private static let freeformPrefix = "itlk/com.apple.iTunes."
    private static let atomPrefix = "itsk/"

    /// AVFoundation reports the legacy `©` byte percent-escaped as `%A9`, and
    /// `%A9` is not valid UTF-8 percent encoding, so decoding it is not an
    /// option — both spellings go in the lookup table instead.
    private static let keysByAtom: [String: TagKey] = {
        var table: [String: TagKey] = [:]
        for (key, atom) in atoms {
            table[atom] = key
            table[atom.replacingOccurrences(of: "©", with: "%A9")] = key
        }
        table["asin"] = .asin
        return table
    }()

    private static let keysByFreeformUpper: [String: TagKey] = {
        var table: [String: TagKey] = [:]
        for (key, name) in freeformNames {
            table[name.uppercased()] = key
        }
        table["GENRE"] = .genre
        return table
    }()

    private static let pairKeysByAtom =
        Dictionary(uniqueKeysWithValues: pairAtoms.map { ($0.atom, ($0.index, $0.total)) })

    static func identifier(for key: TagKey) -> AVMetadataIdentifier? {
        if let atom = atoms[key] {
            return AVMetadataIdentifier(atomPrefix + atom)
        }
        if let name = freeformNames[key] {
            return AVMetadataIdentifier(freeformPrefix + name)
        }
        if case let .custom(name) = key {
            return AVMetadataIdentifier(freeformPrefix + name)
        }
        return nil
    }

    /// The `(index, total)` key pair a packed atom carries, if this is one.
    static func pairKeys(for item: AVMetadataItem) -> (TagKey, TagKey)? {
        guard let raw = item.identifier?.rawValue, raw.hasPrefix(atomPrefix) else { return nil }
        return pairKeysByAtom[String(raw.dropFirst(atomPrefix.count))]
    }

    /// Reverse lookup for a text atom found in a file. Unknown atoms become
    /// `.custom` so a round-trip never silently drops them.
    static func key(for item: AVMetadataItem) -> TagKey? {
        guard let raw = item.identifier?.rawValue else { return nil }
        if raw.hasPrefix("itlk/") {
            let name = if let dotIndex = raw.lastIndex(of: ".") {
                String(raw[raw.index(after: dotIndex)...])
            } else {
                String(raw.dropFirst("itlk/".count))
            }
            // Apple's own gapless-playback atom is machine state, not a user tag.
            guard name != "iTunSMPB" else { return nil }
            return keysByFreeformUpper[name.uppercased()] ?? .custom(name)
        }
        if raw.hasPrefix(atomPrefix) {
            let code = String(raw.dropFirst(atomPrefix.count))
            return keysByAtom[code] ?? .custom(code)
        }
        return .custom(raw)
    }

    static func value(_ string: String, for key: TagKey) -> TagValue {
        if numericKeys.contains(key), let n = Int(string) {
            return .number(n)
        }
        return .string(string)
    }

    /// `index`/`total` packed big-endian into the 8-byte `trkn` / 6-byte `disk` payload.
    static func packedPair(index: Int?, total: Int?, byteCount: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        bytes[2] = UInt8((index ?? 0) >> 8 & 0xFF)
        bytes[3] = UInt8((index ?? 0) & 0xFF)
        bytes[4] = UInt8((total ?? 0) >> 8 & 0xFF)
        bytes[5] = UInt8((total ?? 0) & 0xFF)
        return Data(bytes)
    }

    static func unpackPair(_ data: Data) -> (index: Int?, total: Int?) {
        let bytes = [UInt8](data)
        guard bytes.count >= 6 else { return (nil, nil) }
        let index = Int(bytes[2]) << 8 | Int(bytes[3])
        let total = Int(bytes[4]) << 8 | Int(bytes[5])
        return (index == 0 ? nil : index, total == 0 ? nil : total)
    }
}
